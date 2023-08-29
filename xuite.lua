local urlcode = require("urlcode")
local urlparse = require("socket.url")
local http = require("socket.http")
local https = require("ssl.https")
local xml2lua = require("xml2lua.xml2lua")
local xmlhandler = require("xml2lua.xmlhandler.tree")
local base64 = require("base64")
local md5 = require("md5")
JSON = (loadfile "JSON.lua")()
JSObj = (loadfile "JSObj.lua")()

local xuite_api_key = os.getenv("xuite_api_key")
local xuite_secret_key = os.getenv("xuite_secret_key")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))
local item_type = nil
local item_name = nil
local item_value = nil

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local new_locations = {}

local discovered_outlinks = {}
local discovered_items = {}
local discovered_data = {}
local bad_items = {}
local ids = {}

local retry_url = false
local allow_video = false

local postpagebeta = false
local webpage_404 = false

math.randomseed(os.time())

local EXPANDO = "jQuery111109999999999999999"
local TSTAMP = "1682906400000"

for ignore in io.open("ignore-list", "r"):lines() do
  downloaded[ignore:gsub("^https://", "http://")] = true
  downloaded[ignore:gsub("^http://", "https://")] = true
end

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if not target[item] then
    target[item] = true
    return true
  end
  return false
end

discover_user = function(sn, uid)
  assert(string.match(uid, "^[0-9A-Za-z._]+$"))
  discover_item(discovered_items, "user:" .. uid)
  if type(sn) == "string" then
    assert(string.match(sn, "^[0-9]+$"))
    discover_item(discovered_items, "user-sn:" .. sn)
    discover_item(discovered_data, "user," .. sn .. "," .. uid)
  else
    assert(sn == nil)
  end
end

discover_blog = function(uid, burl, bid)
  assert(string.match(uid, "^[0-9A-Za-z._]+$"))
  -- assert(string.match(burl, "^[0-9A-Za-z]+$")) -- accept malformed blog URLs
  discover_item(discovered_items, "blog:" .. uid .. ":" .. burl)
  if type(bid) == "string" then
    assert(string.match(bid, "^[0-9]+$"))
    discover_item(discovered_items, "blog-api:" .. uid .. ":" .. bid)
    discover_item(discovered_data, "blog," .. bid .. "," .. uid .. "," .. burl)
  else
    assert(bid == nil)
  end
end

discover_article = function(uid, burl, aid, bid)
  assert(string.match(uid, "^[0-9A-Za-z._]+$"))
  -- assert(string.match(burl, "^[0-9A-Za-z]+$")) -- accept malformed blog URLs
  assert(string.match(aid, "^[0-9]+$"))
  discover_item(discovered_items, "article:" .. uid .. ":" .. burl .. ":" .. aid)
  if type(bid) == "string" then
    assert(string.match(bid, "^[0-9]+$"))
    discover_item(discovered_items, "article-api:" .. uid .. ":" .. bid .. ":" .. aid)
  else
    assert(bid == nil)
  end
end

discover_album = function(uid, aid)
  assert(string.match(uid, "^[0-9A-Za-z._]+$"))
  assert(string.match(aid, "^[0-9]+$"))
  discover_item(discovered_items, "album:" .. uid .. ":" .. aid)
end

discover_photo = function(uid, aid, serial)
  assert(string.match(uid, "^[0-9A-Za-z._]+$"))
  assert(string.match(aid, "^[0-9]+$"))
  assert(string.match(serial, "^[0-9]+$"))
  discover_item(discovered_items, "photo:" .. uid .. ":" .. aid .. ":" .. serial)
end

discover_vlog = function(vlogid)
  assert(string.match(vlogid, "^[0-9A-Za-z=]+$"))
  -- generate correctly padded canonical vlogid
	vlogid = #vlogid % 4 == 2 and (vlogid .. '==') or #vlogid % 4 == 3 and (vlogid .. '=') or vlogid
  local mediaid = string.match(base64.decode(vlogid), "%-([0-9]+)%.+[0-9a-z]+$")
  discover_item(discovered_items, "vlog:" .. vlogid)
  if mediaid then
    discover_item(discovered_data, "vlog," .. mediaid .. "," .. vlogid)
  else
    discover_item(discovered_data, "vlog-malformed:" .. vlogid)
  end
  return vlogid
end

discover_keyword = function(keyword)
  -- keyword = keyword:gsub("[%?&=]", "")
  keyword = urlcode.escape(keyword)
  discover_item(discovered_items, "keyword:" .. keyword)
end

parse_args = function(url)
  local parsed_url = urlparse.parse(url)
  local args = {}
  urlcode.parsequery(parsed_url["query"], args)
  return args
end

find_item = function(url)
  local value = string.match(url, "^https?://avatar%.xuite%.net/([0-9]+)$")
  local type_ = "user-sn"
  local other = nil
  if not value then
    value = string.match(url, "^https?://m%.xuite%.net/home/([0-9A-Za-z.][0-9A-Za-z._]*)$")
    type_ = "user"
  end
  if not value then
    local uid, burl = string.match(url, "^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)$")
    if uid and burl then
      value = uid .. ":" .. burl
    end
    type_ = "blog"
  end
  if not value then
    local uid, burl, aid = string.match(url, "^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/([0-9]+)$")
    if uid and burl and aid then
      value = uid .. ":" .. burl .. ":" .. aid
    end
    type_ = "article"
  end
  if not value then
    if string.match(url, "^https?://api%.xuite%.net/api%.php%?") then
      local args = parse_args(url)
      if args["method"] == "xuite.blog.public.getTopArticle" then
        value = args["user_id"] .. ":" .. args["blog_id"]
        type_ = "blog-api"
      elseif args["method"] == "xuite.blog.public.getArticle" then
        value = args["user_id"] .. ":" .. args["blog_id"] .. ":" .. args["article_id"]
        type_ = "article-api"
      end
    end
  end
  if not value then
    local uid, aid = string.match(url, "^https?://m%.xuite%.net/photo/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9]+)$")
    if uid and aid then
      value = uid .. ":" .. aid
    end
    type_ = "album"
  end
  if not value then
    local uid, aid, serial = string.match(url, "^https?://photo%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9]+)/([0-9]+)%.jpg$")
    if uid and aid and serial then
      value = uid .. ":" .. aid .. ":" .. serial
    end
    type_ = "photo"
  end
  if not value then
    value = string.match(url, "^https?://vlog%.xuite%.net/play/([0-9A-Za-z=]+)$")
    type_ = "vlog"
  end
  if not value then
    value = string.match(url, "^https?://pic%.xuite%.net/thumb/(.+)")
    type_ = "pic-thumb"
  end
  if not value then
    value = string.match(url, "^https?://m%.xuite%.net/rpc/search%?method=[a-z]+&kw=([^%?&=]+)&offset=[0-9]+&limit=[0-9]+$")
    if value then
      value = urlcode.unescape(value)
    end
    type_ = "keyword"
  end
  if not value then
    for _, pattern in pairs({
      "^https?://pic%.xuite%.net/[0-9a-f]/?[0-9a-f]/.+$",
      "^https?://img%.xuite%.net/.+$",
      "^https?://blog%.xuite%.net/_service/djshow/mp3/",
      "^https?://blog%.xuite%.net/_service/slideshow/mp3/",
      "^https?://blog%.xuite%.net/_theme/skin/",
      "^https?://blog%.xuite%.net/_users/[0-9a-f]/?[0-9a-f]/.+$",
      "^https?://[0-9a-fs]%.blog%.xuite%.net/.+$",
      "^https?://[0-9a-f]%.mms%.blog%.xuite%.net/.+$",
      "^https?://[0-9a-fs]%.photo%.xuite%.net/.+$",
      "^https?://[0-9a-f]%.share%.photo%.xuite%.net/.+$",
      "^https?://vlog%.xuite%.net/media/.+$"
    }) do
      value = string.match(url, pattern)
      if value then
        if string.match(value, "^https?://blog%.xuite%.net/_users/[0-9a-f]/?[0-9a-f]/") then
          local sn_hash_prefix = string.match(value, "^https?://blog%.xuite%.net/_users/([0-9a-f]).+$")
          value = value:gsub("^https?://blog%.xuite%.net/_users/", "http://" .. sn_hash_prefix .. ".blog.xuite.net/", 1)
        elseif string.match(value, "^https?://[0-9a-f]%.mms%.blog%.xuite%.net/") then
          value = value:gsub("%.mms%.blog%.xuite%.net/", ".blog.xuite.net/", 1)
        end
        if string.match(value, "^https?://[0-9a-f]%.blog%.xuite%.net/[0-9a-f][0-9a-f]/[0-9a-f][0-9a-f]/") then
          local sn_hash = string.match(value, "^https?://[0-9a-f]%.blog%.xuite%.net/([0-9a-f][0-9a-f]/[0-9a-f][0-9a-f])/")
          value = value:gsub(sn_hash, sn_hash:sub(1,1).."/"..sn_hash:sub(2,2).."/"..sn_hash:sub(4,4).."/"..sn_hash:sub(5,5), 1)
        end
        if string.match(value, "^https?://[0-9a-f]%.blog%.xuite%.net/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]/") then
          value = value:gsub("^https", "http", 1)
        end
        value = urlcode.escape(value)
        break
      end
    end
    type_ = "asset"
  end
  if not value then
    value = string.match(url, "^https?://.+%.[Ss][Ww][Ff]$")
    if not value then
      value = string.match(url, "^https?://.+%.[Ss][Ww][Ff]%?[^?]+$")
    end
    if value then
      value = urlcode.escape(value)
    end
    type_ = "embed"
  end
  if value then
    return {
      ["value"]=value,
      ["type"]=type_,
      ["other"]=other
    }
  end
end

set_item = function(url)
  found = find_item(url)
  if found then
    item_type = found["type"]
    item_value = found["value"]
    item_name_new = item_type .. ":" .. item_value
    if item_name_new ~= item_name then
      ids = {}
      ids[item_value] = true
      abortgrab = false
      initial_allowed = false
      tries = 0
      retry_url = false
      allow_video = false
      webpage_404 = false
      item_name = item_name_new
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parenturl)
  if ids[url] then
    return true
  end

  if string.match(url, "/<")
    or string.match(url, "/index%.rdf$")
    or string.match(url, "/'%+urls")
    or string.match(url, "/'%+[A-Za-z%$%[%]_]+%+'$")
    or string.match(url, "/'%+[A-Za-z%$%[%]_]+%+'/s$")
    or string.match(url, "/'%+[A-Za-z%$%[%]_]+%.[A-Za-z%$%[%]_]+%+'$")
    or string.match(url, "/'%+[A-Za-z%$%[%]_]+%.[A-Za-z%$%[%]_]+%.[A-Za-z%$%[%]_]+%+'$")
    or string.match(url, "/%${sn}/s$")
    or string.match(url, "/%${[A-Za-z%$%[%]_]+}$")
    or string.match(url, "/[A-Za-z_]+%${[A-Za-z%$%[%]_]+}$")
    or string.match(url, "/%${[A-Za-z%$%[%]_]+}%${[A-Za-z%$%[%]_]+}$")
    or string.match(url, "^https?://api%.xuite%.net/\\\"https?:\\/\\/.+\\\"$")
    or string.match(url, "^https?://photo%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9]+)/([0-9]+)%.jpg/sizes/[lmst]/$")
    or string.match(url, "^https?://vlog%.xuite%.net/play/[0-9A-Za-z=]*/\"http")
    or string.match(url, "^https?://vlog%.xuite%.net/play/[0-9A-Za-z=]*/?\\/\\/vlog%.xuite%.net")
    or not string.match(url, "^https?://") then
    return false
  end

  for pattern, type_ in pairs({
    ["^https?://avatar%.xuite%.tw/([0-9]+)/s$"]="user-sn",
    ["^https?://avatar%.xuite%.net/([0-9]+)$"]="user-sn",
    ["^https?://avatar%.xuite%.net/([0-9]+)/s$"]="user-sn",
    ["^https?://avatar%.xuite%.net/([0-9]+)/s%?t=[0-9]*$"]="user-sn",
    ["^https?://m%.xuite%.net/home/([0-9A-Za-z._]+)$"]="user",
    ["^https?://m%.xuite%.net/blog/([0-9A-Za-z._]+)$"]="user",
    ["^https?://m%.xuite%.net/blog/([0-9A-Za-z._]+)/([0-9A-Za-z]+)$"]="blog",
    ["^https?://m%.xuite%.net/blog/([0-9A-Za-z._]+)/([0-9A-Za-z]+)/([0-9]+)$"]="article",
    ["^https?://m%.xuite%.net/photo/([0-9A-Za-z._]+)$"]="user",
    ["^https?://m%.xuite%.net/photo/([0-9A-Za-z._]+)%?t=tag&p=[0-9a-f]+$"]="user",
    ["^https?://m%.xuite%.net/photo/([0-9A-Za-z._]+)/([0-9]+)$"]="album",
    ["^https?://m%.xuite%.net/photo/([0-9A-Za-z._]+)/([0-9]+)/([0-9]+)$"]="photo",
    ["^https?://m%.xuite%.net/vlog/([0-9A-Za-z._]+)$"]="user",
    ["^https?://m%.xuite%.net/vlog/([0-9A-Za-z._]+)%?vt=[01]$"]="user",
    ["^https?://m%.xuite%.net/vlog/([0-9A-Za-z._]+)%?t=cat&p=/[0-9]+&dir_num=all$"]="user",
    ["^https?://m%.xuite%.net/vlog/[0-9A-Za-z._]+/([0-9A-Za-z=]+)"]="vlog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)$"]="user",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/?$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/?%?&p=[0-9]+$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/?%?st=c&p=[0-9]+&w=[0-9]+$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/?%?st=c&w=[0-9]+&p=[0-9]+$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/rss%.xml$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/atom%.xml$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/expert%-view$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/list%-view$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/snapshot%-view$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/brick%-view$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/mosaic%-view$"]="blog",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/([0-9]+)$"]="article",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/([0-9]+)/cover[0-9]*%.jpg$"]="article",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/([0-9]+)/cover[0-9]*%.jpg%?d=avatar_[mw]%.jpg$"]="article",
    ["^https?://blog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9A-Za-z]+)/([0-9]+)%-[^/%?&=]*$"]="article",
    ["^https?://photo%.xuite%.net/_category%?st=cat&uid=([0-9A-Za-z._]+)&sk=[0-9]+$"]="user",
    ["^https?://photo%.xuite%.net/_category%?st=cat&uid=([0-9A-Za-z._]+)&sk=[0-9]+%*[0-9]+$"]="user",
    ["^https?://photo%.xuite%.net/_category%?st=search&uid=([0-9A-Za-z._]+)&sk=[^%?&=]*$"]="user",
    ["^https?://photo%.xuite%.net/_category%?st=search&uid=([0-9A-Za-z._]+)&sk=[^%?&=]+%*[0-9]+$"]="user",
    ["^https?://photo%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)$"]="user",
    ["^https?://photo%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9]+)$"]="album",
    ["^https?://photo%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9]+)/([0-9]+)%.jpg$"]="photo",
    ["^https?://photo%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9]+)/([0-9]+)%.jpg/sizes/[ox]/$"]="photo",
    ["^https?://vlog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)$"]="user",
    ["^https?://vlog%.xuite%.net/([0-9A-Za-z.][0-9A-Za-z._]*)%?vt=[01]$"]="user",
    ["^https?://vlog%.xuite%.net/embed/([0-9A-Za-z=]+)"]="vlog",
    ["^https?://vlog%.xuite%.net/play/([0-9A-Za-z=]+)$"]="vlog",
    ["^https?://vlog%.xuite%.net/play/([0-9A-Za-z=]+)/[^/%?&=]+$"]="vlog",
    ["^(https?://pic%.xuite%.net/[0-9a-f]/?[0-9a-f]/.+)$"]="asset",
    ["^https?://pic%.xuite%.net/thumb/(.+)$"]="pic-thumb",
    ["^(https?://img%.xuite%.net/.+)$"]="asset",
    ["^(https?://blog%.xuite%.net/_service/djshow/mp3/.+)$"]="asset",
    ["^(https?://blog%.xuite%.net/_service/slideshow/mp3/.+)$"]="asset",
    ["^(https?://blog%.xuite%.net/_theme/skin/.+)$"]="asset",
    ["^(https?://blog%.xuite%.net/_users/[0-9a-f]/?[0-9a-f]/.+)$"]="asset",
    ["^(https?://[0-9a-fs]%.blog%.xuite%.net/.+)$"]="asset",
    ["^(https?://mms%.blog%.xuite%.net/[0-9a-f]/?[0-9a-f]/.+)$"]="asset",
    ["^(https?://[0-9a-f]%.mms%.blog%.xuite%.net/.+)$"]="asset",
    ["^(https?://[0-9a-fs]%.photo%.xuite%.net/.+)$"]="asset",
    ["^https?://o%.[0-9a-f]%.photo%.xuite%.net/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]/([0-9A-Za-z.][0-9A-Za-z._]*)/([0-9]+)/"]="photo-orig",
    ["^(https?://[0-9a-f]%.share%.photo%.xuite%.net/.+)$"]="asset",
    ["^(https?://vlog%.xuite%.net/media/.+)$"]="asset",
    ["^https?://[0-9a-f]%.mms%.vlog%.xuite%.net/video/[0-9A-Za-z.][0-9A-Za-z._]*/([0-9A-Za-z=]+)%?"]="vlog"
  }) do
    local match = nil
    local other1 = nil
    local other2 = nil
    if type_ == "article" then
      match, other1, other2 = string.match(url, pattern)
      -- a strange behavior of article:mobile is that <a class="page-blogshow-random-link" href="..."> (隨機文章)
      -- sometimes gives (https://m.xuite.net)/blog/blog/{user_id}/{article_id} or deleted articles,
      -- and we knew that the user https://m.xuite.net/blog/blog (user:blog, user-sn:11731848)
      -- has only one blog https://m.xuite.net/blog/blog/blog (blog:blog:blog, blog-api:blog:6063305, https://blog.xuite.net/blog/blog).
      if match == "blog" and other1 ~= nil and other1 ~= "blog" then
        discover_user(nil, other1)
        match = nil
      end
    elseif type_ == "photo" then
      match, other1, other2 = string.match(url, pattern)
    elseif type_ == "blog" or type_ == "album" or type_ == "photo-orig" then
      match, other1 = string.match(url, pattern)
    else
      match = string.match(url, pattern)
    end
    if match then
      if type_ == "blog" then
        discover_blog(match, other1, nil)
        match = match .. ":" .. other1
      elseif type_ == "article" then
        discover_blog(match, other1, nil)
        discover_article(match, other1, other2)
        match = match .. ":" .. other1 .. ":" .. other2
      elseif type_ == "album" then
        discover_album(match, other1)
        match = match .. ":" .. other1
      elseif type_ == "photo" then
        discover_photo(match, other1, other2)
        match = match .. ":" .. other1 .. ":" .. other2
      elseif type_ == "photo-orig" then
        discover_album(match, other1)
        return (item_type == "photo") and true or false
      elseif type_ == "vlog" then
        match = discover_vlog(match)
      elseif type_ == "asset" then
        if string.match(match, "^https?://pic%.xuite%.net/[0-9a-f]/?[0-9a-f]/") then
          discover_item(discovered_items, "asset:" .. urlcode.escape(match))
          -- also use blog.xuite.net/_users
          match = match:gsub("^https?://pic%.xuite%.net/", "http://blog.xuite.net/_users/", 1)
        elseif string.match(match, "^https?://grm%.cdn%.hinet%.net/xuite/[0-9a-f]/?[0-9a-f]/") then
          -- don't use grm.cdn.hinet.net/xuite but use blog.xuite.net/_users instead
          match = match:gsub("^https?://grm%.cdn%.hinet%.net/xuite/", "http://blog.xuite.net/_users/", 1)
        elseif string.match(match, "^https?://mms%.blog%.xuite%.net/[0-9a-f]/?[0-9a-f]/") then
          -- don't use mms.blog.xuite.net but use blog.xuite.net/_users instead
          match = match:gsub("^https?://mms%.blog%.xuite%.net/", "http://blog.xuite.net/_users/", 1)
        end
        if string.match(match, "^https?://blog%.xuite%.net/_users/[0-9a-f]/?[0-9a-f]/") then
          local sn_hash_prefix = string.match(match, "^https?://blog%.xuite%.net/_users/([0-9a-f]).+$")
          match = match:gsub("^https?://blog%.xuite%.net/_users/", "http://" .. sn_hash_prefix .. ".blog.xuite.net/", 1)
        elseif string.match(match, "^https?://[0-9a-f]%.mms%.blog%.xuite%.net/") then
          match = match:gsub("%.mms%.blog%.xuite%.net/", ".blog.xuite.net/", 1)
        end
        if string.match(match, "^https?://[0-9a-f]%.blog%.xuite%.net/[0-9a-f][0-9a-f]/[0-9a-f][0-9a-f]/") then
          local sn_hash = string.match(match, "^https?://[0-9a-f]%.blog%.xuite%.net/([0-9a-f][0-9a-f]/[0-9a-f][0-9a-f])/")
          match = match:gsub(sn_hash, sn_hash:sub(1,1).."/"..sn_hash:sub(2,2).."/"..sn_hash:sub(4,4).."/"..sn_hash:sub(5,5), 1)
        end
        if string.match(match, "^https?://[0-9a-f]%.blog%.xuite%.net/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]/") then
          match = match:gsub("^https", "http", 1)
        end
        match = urlcode.escape(match)
      end
      local new_item = type_ .. ":" .. match
      if new_item ~= item_name then
        discover_item(discovered_items, new_item)
        return false
      else
        return true
      end
    end
  end

  if string.match(url, "^https?://blog%.xuite%.net/blog_pwd%.php")
    or string.match(url, "^https?://photo%.xuite%.net/_category%?")
    or string.match(url, "^https?://vlog%.xuite%.net/_playlist/play%?")
    or string.match(url, "^https?://vlog%.xuite%.net/_pub/conf_playlist_v2%.php%?")
    or string.match(url, "^https?://vlog%.xuite%.net/flash/playlist%?")
    or string.match(url, "^https?://vlog%.xuite%.net/play/[0-9A-Za-z=]+%?as=1&list=[0-9]+$")
    or string.match(url, "^https?://events%.xuite%.net/")
    or string.match(url, "^https?://wms%.map%.xuite%.net/")
    or string.match(url, "^https?://town%.xuite%.net/")
    -- API
    or string.match(url, "^https?://api%.xuite%.net/api%.php%?")
    or string.match(url, "^https?://api%.xuite%.net/oembed/%?")
    or string.match(url, "^https?://blog%.xuite%.net/_service/smallpaint/list%.php%?")
    or (string.match(url, "^https?://blog%.xuite%.net/_theme/[A-Za-z]+%.php%?") and not string.match(url, "^https?://blog%.xuite%.net/_theme/GAExp%.php%?"))
    or string.match(url, "^https?://m%.xuite%.net/rpc/search%?")
    or string.match(url, "^https?://m%.xuite%.net/rpc/blog%?")
    or string.match(url, "^https?://m%.xuite%.net/rpc/photo%?")
    or string.match(url, "^https?://m%.xuite%.net/rpc/vlog%?")
    or string.match(url, "^https?://m%.xuite%.net/vlog/ajax%?")
    or string.match(url, "^https?://photo%.xuite%.net/_feed/album%?")
    or string.match(url, "^https?://photo%.xuite%.net/_feed/photo%?")
    or string.match(url, "^https?://photo%.xuite%.net/_friends$")
    or string.match(url, "^https?://photo%.xuite%.net/_pic/[0-9A-Za-z._]+/[0-9]+/[0-9]+%.jpg/redir")
    or string.match(url, "^https?://photo%.xuite%.net/_pic/[0-9A-Za-z._]+/[0-9]+/[0-9]+_[A-Za-z]%.jpg/redir")
    or string.match(url, "^https?://photo%.xuite%.net/_r9009/[0-9A-Za-z._]+/[0-9]+/[0-9]+%.jpg")
    or string.match(url, "^https?://photo%.xuite%.net/@tag_lib_js$")
    or string.match(url, "^https?://vlog%.xuite%.net/_api/media/playcheck/media/[0-9A-Za-z=]+$")
    or string.match(url, "^https?://vlog%.xuite%.net/flash/player%?media=[0-9A-Za-z=]+$")
    or string.match(url, "^https?://vlog%.xuite%.net/flash/audioplayer%?media=[0-9A-Za-z=]+$")
    or string.match(url, "^https?://my%.xuite%.net/api/visitor2xml%.php%?")
    -- Original resolution photos require a valid Referer header
    or string.match(url, "^https?://o%.[0-9a-f]%.photo%.xuite%.net/")
    -- Vlog files require a valid session key
    or string.match(url, "^https?://[0-9a-f]%.mms%.vlog%.xuite%.net/") then
    return true
  end

  if string.match(url, "^https?://[^/]*xuite%.net/")
    or string.match(url, "^https?://[^/]*xuite%.tw/")
    or string.match(url, "^https?://[^/]*xuite%.com/") then
    for _, pattern in pairs({
      "([a-zA-Z0-9%-_]+)",
      "([a-zA-Z0-9%%%-_]+)",
      "([^/%?&]]+)"
    }) do
      for s in string.gmatch(string.match(url, "^https?://[^/]+(/.*)"), pattern) do
        if ids[s] then
          return true
        end
      end
    end
    if
      -- invalid, deprecated, requires login, duplicate swf, or should not be requested with GET
         string.match(url, "^https?://blog%.xuite%.net/_my2/")
      or string.match(url, "^https?://blog%.xuite%.net/_members/login%.php%?")
      or string.match(url, "^https?://blog%.xuite%.net/_theme/item/article_lock%.php%?")
      or string.match(url, "^https?://blog%.xuite%.net/_theme/message/message_delete%.php%?")
      or string.match(url, "^https?://blog%.xuite%.net/_theme/trackback/track_delete%.php%?")
      or string.match(url, "^https?://blog%.xuite%.net/aboutme%.phtml%?lid=[0-9A-Za-z._]+$")
      or string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z.][0-9A-Za-z._]*/[0-9A-Za-z]+%?amp;")
      or string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z.][0-9A-Za-z._]*/[0-9A-Za-z]+/[0-9]+/track$")
      or string.match(url, "^https?://event%.xuite%.net/")
      or string.match(url, "^https?://m%.xuite%.net/photo/[0-9A-Za-z._]+/[0-9]+%-[^/%?&=]*$")
      or string.match(url, "^https?://m%.xuite%.net/photo/[0-9A-Za-z._]+/js/jquery%.floatit%.js$")
      or string.match(url, "^https?://my%.xuite%.net/api/visit%.php%?")
      or string.match(url, "^https?://my%.xuite%.net/error.php%?channel=www&ecode=Nodata$")
      or string.match(url, "^https?://mywall%.xuite%.net/")
      or string.match(url, "^https?://photo%.xuite%.net/@login")
      or string.match(url, "^https?://photo%.xuite%.net/_picinfo/exif$")
      or string.match(url, "^https?://roomi%.xuite%.net/")
      or string.match(url, "^https?://vip%.xuite%.net/$")
      or string.match(url, "^https?://vlog%.xuite%.net/_a/")
      or string.match(url, "^https?://vlog%.xuite%.net/_auth/")
      or string.match(url, "^https?://vlog%.xuite%.net/_my2/")
      or string.match(url, "^https?://vlog%.xuite%.net/_pa/")
      or string.match(url, "^https?://vlog%.xuite%.net/_v/")
      or string.match(url, "^https?://vlog%.xuite%.net/_v001/")
      or string.match(url, "^https?://vlog%.xuite%.net/_v002/")
      or string.match(url, "^https?://vlog%.xuite%.net/_v004/")
      or string.match(url, "^https?://vlog%.xuite%.net/_vm001/")
      or string.match(url, "^https?://vote%.xuite%.net/")
      -- <meta property="og:url" content="m.xuite.net//[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+"/>
      or string.match(url, "^https?://m%.xuite%.net/blog/[0-9A-Za-z._]+/[0-9A-Za-z]+/m%.xuite%.net//blog/[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+")
      or string.match(url, "^https?://m%.xuite%.net/blog/[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+/m%.xuite%.net//blog/[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+") then
      return false
    elseif
      -- asset
         string.match(url, "%.jpg$") or string.match(url, "%.jpg%?[^?]*$")
      or string.match(url, "%.jpeg$") or string.match(url, "%.jpeg%?[^?]*$")
      or string.match(url, "%.ico$") or string.match(url, "%.ico%?[^?]*$")
      or string.match(url, "%.gif$") or string.match(url, "%.gif%?[^?]*$")
      or string.match(url, "%.bmp$") or string.match(url, "%.bmp%?[^?]*$")
      or string.match(url, "%.png$") or string.match(url, "%.png%?[^?]*$")
      or string.match(url, "%.svg$") or string.match(url, "%.svg%?[^?]*$")
      or string.match(url, "%.avi$") or string.match(url, "%.avi%?[^?]*$")
      or string.match(url, "%.wmv$") or string.match(url, "%.wmv%?[^?]*$")
      or string.match(url, "%.flv$") or string.match(url, "%.flv%?[^?]*$")
      or string.match(url, "%.mp4$") or string.match(url, "%.mp4%?[^?]*$")
      or string.match(url, "%.wav$") or string.match(url, "%.wav%?[^?]*$")
      or string.match(url, "%.mp3$") or string.match(url, "%.mp3%?[^?]*$")
      or string.match(url, "%.wma$") or string.match(url, "%.wma%?[^?]*$")
      or string.match(url, "%.mid$") or string.match(url, "%.mid%?[^?]*$")
      or string.match(url, "%.css$") or string.match(url, "%.css%?[^?]*$")
      or string.match(url, "%.js$") or string.match(url, "%.js%?[^?]*$")
      or string.match(url, "%.xml$") or string.match(url, "%.xml%?[^?]*$")
      -- pages
      or string.match(url, "%.htm$") or string.match(url, "%.htm%?[^?]*$")
      or string.match(url, "%.html$") or string.match(url, "%.html%?[^?]*$")
      or string.match(url, "%.phtml$") or string.match(url, "%.phtml%?[^?]*$")
      or string.match(url, "%.php$") or string.match(url, "%.php%?[^?]*$") then
      return true
    elseif string.match(url, "%.swf$") or string.match(url, "%.swf%?[^?]*$") then
      -- TODO: inspect the collected xuite-data backfeed to discover FlashVars rules
      discover_item(discovered_items, "embed:" .. urlcode.escape(url))
      return false
    else
      -- TODO: can we throw the rest into URLs?
      -- are they guaranteed to be downloaded before the deadline?
      discover_item(discovered_data, "other," .. urlcode.escape(url))
      discover_item(discovered_outlinks, url)
      return false
    end
  end

  if
    -- static
        not string.match(url, "^https?://ssp%.hinet%.net/")
    and not string.match(url, "^https?://t%.ssp%.hinet%.net/")
    and not string.match(url, "^https?://static%.cht%.hinet%.net/")
    and not string.match(url, "^https?://cdnjs%.cloudflare%.com/")
    and not string.match(url, "^https?://fonts%.googleapis%.com/")
    and not string.match(url, "^https?://code%.jquery%.com/")
    and not string.match(url, "^https?://cdn%.jsdelivr%.net/")
    and not string.match(url, "^https?://openlayers%.org/")
    and not string.match(url, "^https?://unpkg%.com/")
    and not string.match(url, "^https?://videojs%.com/")
    -- track
    and not string.match(url, "^https?://[^/]*googletagmanager%.com/")
    and not string.match(url, "^https?://pclick%.yahoo%.com/")
    -- ad
    and not string.match(url, "^https?://[^/]*adsinstant%.com/")
    and not string.match(url, "^https?://[^/]*aralego%.net/")
    and not string.match(url, "^https?://[^/]*cloudfront%.net/")
    and not string.match(url, "^https?://[^/]*doubleclick%.net/")
    and not string.match(url, "^https?://[^/]*focusoftime%.com/")
    and not string.match(url, "^https?://imasdk%.googleapis%.com/")
    and not string.match(url, "^https?://[^/]*googlesyndication%.com/")
    -- share
    and not string.match(url, "^https?://plus%.google%.com/share%?")
    and not string.match(url, "^https?://chart%.googleapis%.com/chart%?cht=qr")
    and not string.match(url, "^https?://www%.facebook%.com/sharer%.php%?")
    and not string.match(url, "^https?://www%.facebook%.com/sharer/sharer%.php%?")
    and not string.match(url, "^https?://line%.naver%.jp/R/msg/text/%?")
    and not string.match(url, "^https?://www%.plurk%.com/m%?qualifier=shares")
    and not string.match(url, "^https?://twitter%.com/intent/tweet%?")
    and not string.match(url, "^https?://twitter%.com/%?status=") then
    discover_item(discovered_outlinks, url)
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  if allowed(url, parent["url"]) and not processed(url) then
    addedtolist[url] = true
    return true
  end

  return false
end

local user_sn_tbl = {}
local user_id_tbl = {}
local blog_url_tbl = {}

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil

  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function decode_codepoint(newurl)
    newurl = string.gsub(
      newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
      function (s)
        return unicode_codepoint_as_utf8(tonumber(s, 16))
      end
    )
    return newurl
  end

  local function fix_case(newurl)
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl, referer)
    newurl = decode_codepoint(newurl)
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_)
      and not processed(url_ .. "/")
      and allowed(url_, origurl) then
      local isXHR = false
      if string.match(url_, "^https?://blog%.xuite%.net/_theme/[A-Za-z]+%.php%?") then
        assert(string.match(referer, "^https?://blog%.xuite%.net/[0-9A-Za-z.][0-9A-Za-z._]*/[0-9A-Za-z._]+"))
        isXHR = true
      elseif string.match(url_, "^https?://m%.xuite%.net/rpc/blog%?") then
        assert(string.match(referer, "^https?://m%.xuite%.net/blog/"))
        isXHR = true
      elseif string.match(url_, "^https?://m%.xuite%.net/rpc/photo%?") then
        assert(string.match(referer, "^https?://m%.xuite%.net/photo/"))
        isXHR = true
      elseif string.match(url_, "^https?://m%.xuite%.net/rpc/vlog%?")
        or string.match(url_, "^https?://m%.xuite%.net/vlog/ajax%?") then
        assert(string.match(referer, "^https?://m%.xuite%.net/vlog/"))
        isXHR = true
      end
      if isXHR then
        table.insert(urls, {
          url=url_,
          headers={
            ["Accept"] = "application/json, text/javascript, */*; q=0.01",
            ["Referer"] = referer,
            ["X-Requested-With"] = "XMLHttpRequest"
          }
        })
      elseif string.match(url_, "^https?://photo%.xuite%.net/[0-9A-Za-z._]+/[0-9]+/[0-9]+%.jpg%??[^/%?]*$") then
        table.insert(urls, {
          url=url_,
          headers={
            ["Cookie"] = "exif=1",
            ["Referer"] = "https://m.xuite.net/"
          }
        })
      elseif string.match(url_, "^https?://o%.[0-9a-f]%.photo%.xuite%.net/") then
        table.insert(urls, {
          url=url_,
          headers={
            ["Referer"] = "https://photo.xuite.net/"
          }
        })
      elseif referer then
        table.insert(urls, {
          url=url_,
          headers={
            ["Referer"] = referer
          }
        })
      else
        table.insert(urls, { url=url_ })
      end
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function flatten_json(json)
    local result = ""
    for k, v in pairs(json) do
      result = result .. " " .. k
      local type_v = type(v)
      if type_v == "string" then
        v = string.gsub(v, "\\", "")
        result = result .. " " .. v .. ' "' .. v .. '"'
      elseif type_v == "table" then
        result = result .. " " .. flatten_json(v)
      end
    end
    return result
  end

  local redir_url = string.match(url, "^https?://redir%.xuite%.net/[a-z_/]*%^(https?://[^/]*xuite%.net/.*)$")
  if redir_url then
    check(redir_url)
  end

  if item_type == "user-sn" then
    if string.match(url, "^https?://avatar%.xuite%.net/[0-9]+$") then
      assert(string.match(url, "^https?://avatar%.xuite%.net/([0-9]+)$") == item_value)
      check("https://my.xuite.net/service/friend/api/external/friendList.php?sn="..item_value.."&listType=addme")
      check("https://my.xuite.net/service/friend/api/external/friendList.php?sn="..item_value.."&listType=friend&withGroup=false")
      check("https://my.xuite.net/service/friend/api/external/friendList.php?sn="..item_value.."&listType=friend&withGroup=true&callback=addFriendList&rnd="..TSTAMP)
      check("https://my.xuite.net/service/account/api/external/sn_name.php?sn="..item_value.."&callback="..EXPANDO.."_"..TSTAMP.."&_="..TSTAMP)
      check("https://blog.xuite.net/_theme/snapshot/snapshot_avatar.php?mid="..item_value)
      local sn_hash = md5.sumhexa(item_value)
      for _, asset_name in pairs({ "photo.jpg", "avatar.jpg", "face.xml" }) do
        local sn_prefix = sn_hash:sub(1,1).."/"..sn_hash:sub(2,2).."/"..sn_hash:sub(3,3).."/"..sn_hash:sub(4,4).."/"
        check("https://" .. sn_hash:sub(1,1) .. ".blog.xuite.net/" .. sn_prefix .. item_value .. "/" .. asset_name)
      end
      check(url .. "/s")
    elseif string.match(url, "^https?://blog%.xuite%.net/_theme/snapshot/snapshot_avatar%.php%?mid=[0-9]+$") then
      local user_sn = string.match(url, "^https?://blog%.xuite%.net/_theme/snapshot/snapshot_avatar%.php%?mid=([0-9]+)$")
      html = read_file(file)
      local sn = string.match(html, "<div class=\"avatarPhoto\"><img src=\"//avatar%.xuite%.net/([0-9]+)\"></div>")
      local uid = string.match(html, "<br><br><a href=\"//photo%.xuite%.net/([0-9A-Za-z._]+)\" alt=")
      if sn and uid then
        if user_sn == sn then
          discover_user(sn, uid)
        else
          abort_item()
        end
      else
        print("Found nothing from snapshot_avatar")
      end
      check("https://photo.xuite.net/_category?sn=" .. user_sn)
    elseif string.match(url, "^https?://my%.xuite%.net/service/account/api/external/sn_name%.php%?") then
      -- html = read_file(file)
      -- local json = JSON:decode(string.match(html, "^jQuery[0-9]+_[0-9]+%((.+)%)\r\n$"))
      -- if json["nickname"] and string.len(json["nickname"]) >= 1 then
      --   discover_keyword(json["nickname"])
      -- end
    elseif string.match(url, "^https?://my%.xuite%.net/service/friend/api/external/friendList%.php%?sn=") and not string.match(url, "&withGroup=true") then
      html = read_file(file)
      if not string.match(html, "^NULL$")
        and not string.match(html, "^%[%]$") then
        local json = JSON:decode(html)
        for _, friendship in pairs(json) do
          if friendship["sn"] and friendship["uid"] then
            local sn = string.match(friendship["sn"], "^[0-9]+$")
            local uid = string.match(friendship["uid"], "^[0-9A-Za-z._]+$")
            if sn and uid then
              discover_user(sn, uid)
            else
              abort_item()
            end
          end
        end
      else
        print("Found nothing from friendList")
      end
    -- no need to save "photo.xuite.net/_category?sn=...$"
    elseif string.match(url, "^https?://photo%.xuite%.net/_category%?sn=[0-9]+$") then
      local user_sn = string.match(url, "^https?://photo%.xuite%.net/_category%?sn=([0-9]+)$")
      html = read_file(file)
      local sn = string.match(html, "<p>檢舉需要<a href=\"/@login%?furl=%%2F_category%%3Fsn%%3D([0-9]+)\">登入會員 &raquo;</a>。</p>")
      if not (user_sn == sn) then
        abort_item()
      end
      -- user:album:search 搜尋相簿
      local uid = string.match(html, "<input id=\"searchUid\" type=\"hidden\" value=\"([0-9A-Za-z._]*)\">")
      -- this widget can be turned off by the user. so if searchUid does not appear, the user must exist
      if not uid then
        local uid = string.match(html, "<div class=\"avatar side\">[^<>]*<div class=\"avatarPhoto\">[^<>]*<a href=\"//xuite%.net/([0-9A-Za-z._]*)\"[^t<>]*title=\"[^\"]*\">[^<>]*<img[^<>]*></a>[^<>]*</div>")
      end
      if not uid then
        abort_item()
      end
      if string.len(uid) >= 1 then
        discover_user(sn, uid)
      else
        print("Found nothing from photo_category")
      end
    end
  end

  if item_type == "user" then
    -- user:home
    if string.match(url, "^https?://m%.xuite%.net/home/[0-9A-Za-z._]+$") then
      assert(string.match(url, "^https?://m%.xuite%.net/home/([0-9A-Za-z._]+)$") == item_value)
      html = read_file(file)
      local sn = string.match(html, "<img class=\"mywall%-thumb%-img\" onclick='%$%(\"#nft%-info%-modal\"%)%.modal%(\"show\"%);' src=\"//avatar%.xuite%.net/([0-9]+)/s%?t=[0-9]+\">")
      local uid = string.match(html, "<link rel=\"canonical\" href=\"//mywall%.xuite%.net/([0-9A-Za-z._]+)\" />")
      if sn and uid then
        if uid == item_value then
          discover_user(sn, uid)
          user_sn_tbl[uid] = sn
        else
          abort_item()
        end
      end
      check("https://photo.xuite.net/_feed/album?user_id=" .. item_value)
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. "xuite.vlog.public.getDirs" .. item_value)
        .. "&method=xuite.vlog.public.getDirs"
        .. "&user_id=" .. item_value
      )
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. "10000" .. "xuite.vlog.public.getVlogs" .. "0" .. "" .. item_value)
        .. "&method=xuite.vlog.public.getVlogs"
        .. "&user_id=" .. item_value
        .. "&start=" .. "0"
        .. "&limit=" .. "10000"
        .. "&type="
      )
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. "" .. "" .. "xuite.photo.public.getAlbums" .. "0" .. item_value)
        .. "&method=xuite.photo.public.getAlbums"
        .. "&user_id=" .. item_value
        .. "&event_set="
        .. "&start=" .. "0"
        .. "&limit="
      )
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. "xuite.blog.public.getBlogs" .. item_value)
        .. "&method=xuite.blog.public.getBlogs"
        .. "&user_id=" .. item_value
      )
      check("https://m.xuite.net/vlog/"..item_value)
      check("https://m.xuite.net/photo/"..item_value)
      check("https://m.xuite.net/blog/"..item_value)
      -- user:friend 我的好友
      -- https://photo.xuite.net/javascripts/picture_user.comb.js if ($("#FriendList").length > 0) window.WIDGET.FRIEND.init() $.ajax({})
      -- this widget can be turned off by the user
      table.insert(urls, {
        url="https://photo.xuite.net/_friends",
        headers={ ["Origin"] = "https://photo.xuite.net", ["Referer"] = (sn and ("https://photo.xuite.net/_category?sn=" .. sn) or nil), ["X-Requested-With"] = "XMLHttpRequest" },
        post_data="act=getAllFriendsList&uid=" .. item_value
      })
      -- user:about 關於我
      -- https://photo.xuite.net/javascripts/picture_user.comb.js if ($("#avatarContent").length > 0) window.WIDGET.AVATAR.init() $.ajax({})
      check("https://blog.xuite.net/_theme/member_data.php?callback="..EXPANDO.."_"..TSTAMP.."&lid="..item_value.."&output=json&callback=WIDGET.AVATAR.processDesc&_="..TSTAMP, "https://photo.xuite.net/")
    -- user:about
    elseif string.match(url, "^https?://blog%.xuite%.net/_theme/member_data%.php%?.+&lid=[0-9A-Za-z._]+.+&callback=WIDGET%.AVATAR%.processDesc") then
      local user_id = string.match(url, "^https?://blog%.xuite%.net/_theme/member_data%.php%?.+&lid=([0-9A-Za-z._]+).+&callback=WIDGET%.AVATAR%.processDesc")
      html = read_file(file)
      local json = JSON:decode(string.match(html, "^WIDGET%.AVATAR%.processDesc%((.+)%);$"))
      -- TODO: this API sometimes returns invalid XML characters or non-UTF8 characters, so don't use xml2lua.
      -- how to filter out XML CDATA without xml2lua if someone put "<blog>//blog.xuite.net/..." in their introduction?
      local sn = string.match(json, "    <pic>//avatar%.xuite%.net/([0-9]+)/s</pic>")
      local uid = string.match(json, "  <blog>//blog%.xuite%.net/([0-9A-Za-z._]+)</blog>")
      if sn and uid then
        if uid == user_id then
          discover_user(sn, uid)
        else
          abort_item()
        end
      else
        print("Found nothing from member_data")
      end
    -- user:friend
    elseif string.match(url, "^https?://photo%.xuite%.net/_friends$") then
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ret"] then
        for _, group in pairs(json["data"]) do
          for _, friend in pairs(group["grouplist"]) do
            local sn = string.match(friend["sn"], "^[0-9]+$")
            local uid = string.match(friend["uid"], "^[0-9A-Za-z._]+$")
            if sn and uid then
              discover_user(sn, uid)
            else
              abort_item()
            end
          end
        end
      end
    -- user:blog
    elseif string.match(url, "^https?://m%.xuite%.net/blog/[0-9A-Za-z._]+$") then
      local user_id = string.match(url, "^https?://m%.xuite%.net/blog/([0-9A-Za-z._]+)$")
      assert(user_id == item_value)
    -- user:blog:smallpaint
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/smallpaint/list%.php%?") then
      html = read_file(file)
      local handler = xmlhandler:new()
      xml2lua.parser(handler):parse(html)
      if handler.root["DRAW"]["ALBUM"] then
        if handler.root["DRAW"]["ALBUM"]["_attr"] then
          check(handler.root["DRAW"]["ALBUM"]["_attr"]["LINK"])
        else
          for _, ALBUM in pairs(handler.root["DRAW"]["ALBUM"]) do
            check(ALBUM["_attr"]["LINK"])
          end
        end
      elseif handler.root["DRAW"]["_attr"]["TOTAL"] ~= "0" and tostring(handler.root["DRAW"]["_attr"]["TOTAL"]) ~= "0" then
        abort_item()
      end
    -- user:album
    elseif string.match(url, "^https?://m%.xuite%.net/photo/[0-9A-Za-z._]+$") then
      local user_id = string.match(url, "^https?://m%.xuite%.net/photo/([0-9A-Za-z._]+)$")
      html = read_file(file)
      local sn, uid = string.match(html, "<img class=\"albumlist%-thumb%-img\" src=\"//avatar%.xuite%.net/([0-9]+)/s%?t=[0-9]+\" onclick=\"location%.href='/home/([0-9A-Za-z._]+)';\">")
      if not sn or not uid then
        sn, uid = string.match(html, "<img class=\"nftmywall%-thumb%-img\" src=\"//avatar%.xuite%.net/([0-9]+)/s%?t=[0-9]+\" onclick=\"location%.href='/home/([0-9A-Za-z._]+)';\">")
      end
      if not new_locations[url] then
        if not (sn and uid) then
          print(url)
          abort_item()
        end
      end
      if sn then
        assert(uid == user_id)
        user_id_tbl[sn] = uid
        -- user:album:tag 天邊一朵雲
        -- https://photo.xuite.net/_category?
        -- https://s.photo.xuite.net/static/tag_js/tag_js_config.js
        -- https://photo.xuite.net/javascripts/picture_user.comb.js if ($("#tagSide").length > 0) window.WIDGET.TAG.init() XMLHttp.sendReq()
        -- https://s.photo.xuite.net/static/tag_js/tagsystem.js tag_getUserTagCloudAttached($("#widget_tag_key").val(),"photo","yes","tagSide");
        table.insert(urls, {
          url="https://photo.xuite.net/@tag_lib_js",
          headers={ ["Origin"] = "https://photo.xuite.net", ["Referer"] = "https://photo.xuite.net/_category?sn=" .. sn },
          post_data="command=getUserTagCloud&sn=" .. sn .. "&service=photo&tagcloud=no&userid=@000"
        })
        table.insert(urls, {
          url="https://photo.xuite.net/@tag_lib_js",
          headers={ ["Origin"] = "https://photo.xuite.net", ["Referer"] = "https://photo.xuite.net/_category?sn=" .. sn },
          post_data="command=getUserTagCloud&sn=" .. sn .. "&service=photo&tagcloud=yes&userid=@000"
        })
      end
      -- $(document).on('click','.albumlist-more',function(e){...});
      if string.match(html, "<a class=\"albumlist%-more\" href=\"javascript:void%(0%);\">more</a>") then
        local val_uid = string.match(html, "<input type=\"hidden\" id=\"uid\" value=\"([0-9A-Za-z._]+)\">")
        local data_cnt = string.match(html, "<div class=\"xmui%-page%-more\" data%-cnt=\"([0-9]*)\">")
        local val_tag_id = string.match(html, "<input type=\"hidden\" id=\"tag_id\" value=\"([0-9a-f]+)\">")
        assert(val_uid == user_id, val_uid)
        assert(data_cnt == "12", data_cnt)
        assert(val_tag_id == nil, val_tag_id)
        check("https://m.xuite.net/rpc/photo?method=loadAlbums&userId=" .. val_uid .. "&limit=12&offset=12&sk=&p=", url)
      elseif not new_locations[url] then
        local count = string.match(html, "<p class=\"albumlist%-info%-count\"><span>粉絲 [0-9]+</span>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<span>相簿 ([0-9]+)</span></p>")
        if not count or not (tonumber(count) <= 12) then
          print(url)
          abort_item()
        end
      end
    elseif string.match(url, "^https?://photo%.xuite%.net/_feed/album%?") then
      html = read_file(file)
      local json = JSON:decode(html)
      if json["error"] then
        assert(json["error"] == "User close album: You cannot get photo list", json["error"])
      else
        for _, album in pairs(json["albums"]) do
          discover_album(json["user_id"], album["album_id"])
          check("https://photo.xuite.net/_category?st=cat&uid=" .. json["user_id"] .. "&sk=" .. album["category_id"])
        end
      end
    elseif string.match(url, "^https?://m%.xuite%.net/rpc/photo%?method=loadAlbums&userId=[0-9A-Za-z._]+&limit=12&offset=[0-9]+&sk=&p=$") then
      local user_id, offset = string.match(url, "^https?://m%.xuite%.net/rpc/photo%?method=loadAlbums&userId=([0-9A-Za-z._]+)&limit=12&offset=([0-9]+)&sk=&p=$")
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ok"] then
        local rsp_n = 0
        local referer = "https://m.xuite.net/photo/" .. user_id
        for _, rsp in pairs(json["rsp"]) do
          check(rsp["thumb"], referer)
          rsp_n = rsp_n + 1
        end
        if json["_ismore"] then
          check("https://m.xuite.net/rpc/photo?method=loadAlbums&userId=" .. user_id .. "&limit=12&offset=" .. string.format("%.0f", tonumber(offset) + rsp_n) .. "&sk=&p=", referer)
        end
      end
    -- user:album:tag
    elseif string.match(url, "^https?://photo%.xuite%.net/@tag_lib_js$") then
      html = read_file(file)
      local json = JSON:decode(html)
      for _, tag in pairs(json) do
        if tag["tagid"] == "999" then
          if tag["tagname"] ~= "尚無任何標籤 , 請新增標籤!" then
            print("Unexpected tagname (" .. tag["tagname"] .. ") in " .. url)
            abort_item()
          end
        else
          if string.match(tag["sn"], "^[0-9]+$") then
            if string.match(tag["tagid"], "^[0-9a-f]+$") then
              if tag["link"] == "//photo.xuite.net/_category?sn=" .. tag["sn"] .. "&tagid=" .. tag["tagid"] then
                check("https:" .. tag["link"])
              else
                print("Unexpected tag link (" .. tag["link"] .. ")")
                abort_item()
              end
              if user_id_tbl[tag["sn"]] then
                check("https://m.xuite.net/photo/" .. user_id_tbl[tag["sn"]] .. "?t=tag&p=" .. tag["tagid"])
              else
                print("Cannot infer user_id for user-sn " .. tag["sn"])
                abort_item()
              end
            else
              print("Unexpected tagid " .. tag["tagid"] .. " in " .. url)
              abort_item()
            end
          else
            print("Cannot find user-sn")
            abort_item()
          end
        end
      end
    elseif string.match(url, "^https?://m%.xuite%.net/photo/[0-9A-Za-z._]+%?t=tag&p=[0-9a-f]+$") then
      local user_id, tagid = string.match(url, "^https?://m%.xuite%.net/photo/([0-9A-Za-z._]+)%?t=tag&p=([0-9a-f]+)$")
      html = read_file(file)
      -- $(document).on('click','.albumlist-more',function(e){...});
      if string.match(html, "<a class=\"albumlist%-more\" href=\"javascript:void%(0%);\">more</a>") then
        local val_uid = string.match(html, "<input type=\"hidden\" id=\"uid\" value=\"([0-9A-Za-z._]+)\">")
        local data_cnt = string.match(html, "<div class=\"xmui%-page%-more\" data%-cnt=\"([0-9]*)\">")
        local val_tag_id = string.match(html, "<input type=\"hidden\" id=\"tag_id\" value=\"([0-9a-f]+)\">")
        assert(val_uid == user_id, val_uid)
        assert(data_cnt == "12", data_cnt)
        assert(val_tag_id == tagid, val_tag_id)
        check("https://m.xuite.net/rpc/photo?method=loadAlbums&userId=" .. val_uid .. "&limit=12&offset=12&sk=&p=" .. val_tag_id, url)
      elseif not new_locations[url] then
        local count = string.match(html, "<div class=\"albumlist%-Subdirectory\" > <span>個人相簿＞標籤為 .*的相簿%(共([0-9]+)本%)</span><a href=\"/photo/[0-9A-Za-z._]+\">回相簿列表</a> </div>")
        if not count or not (tonumber(count) <= 12) then
          print(url)
          abort_item()
        end
      end
    elseif string.match(url, "^https?://photo%.xuite%.net/_category%?sn=[0-9]+&tagid=[0-9a-f]+$") then
      -- do nothing
    elseif string.match(url, "^https?://m%.xuite%.net/rpc/photo%?method=loadAlbums&userId=[0-9A-Za-z._]+&limit=12&offset=[0-9]+&sk=&p=[0-9a-f]+$") then
      local user_id, offset, tagid = string.match(url, "^https?://m%.xuite%.net/rpc/photo%?method=loadAlbums&userId=([0-9A-Za-z._]+)&limit=12&offset=([0-9]+)&sk=&p=([0-9a-f]+)$")
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ok"] then
        local rsp_n = 0
        local referer = "https://m.xuite.net/photo/" .. user_id .. "?t=tag&p=" .. tagid
        for _, rsp in pairs(json["rsp"]) do
          check(rsp["thumb"], referer)
          rsp_n = rsp_n + 1
        end
        if json["_ismore"] then
          check("https://m.xuite.net/rpc/photo?method=loadAlbums&userId=" .. user_id .. "&limit=12&offset=" .. string.format("%.0f", tonumber(offset) + rsp_n) .. "&sk=&p=", referer)
        end
      end
    -- user:album:category
    elseif string.match(url, "^https?://photo%.xuite%.net/_category%?st=cat&uid=[0-9A-Za-z._]+&sk=[0-9]+$") then
      local user_id = string.match(url, "^https?://photo%.xuite%.net/_category%?st=cat&uid=([0-9A-Za-z._]+)&sk=[0-9]+$")
      html = read_file(file)
      -- user:album:visitor 誰拜訪過我
      -- this widget can be turned off by the user, causing the visitor_key not to be displayed
      local visitor_key = string.match(html, "\r\n    <script>\r\n        new XUI%.Widgets%.Visitor%(document%.getElementById%('visitorList'%), {\r\n            key : '([0-9A-Za-z=]+)'\r\n        }%)%.render%(%); \r\n    </script>\r\n")
      if visitor_key then
        assert(base64.decode(visitor_key) == "http://photo.xuite.net/" .. user_id .. "/")
      else
        visitor_key = base64.encode("http://photo.xuite.net/" .. user_id .. "/")
      end
      check("https://my.xuite.net/api/visitor2xml.php" ..
        "?callback=" .. EXPANDO.."_"..TSTAMP ..
        "&set=15" ..
        "&key=" .. visitor_key ..
        "&_=" .. TSTAMP
      , "https://photo.xuite.net/")
    -- user:album:visitor
    elseif string.match(url, "^https?://my%.xuite%.net/api/visitor2xml%.php%?") then
      html = read_file(file)
      local json = JSON:decode(string.match(html, "^jQuery[0-9]+_[0-9]+%((.+)%)$"))
      if json["items"] then
        for _, item in pairs(json["items"]) do
          discover_user(item["MEMBERID"], item["LOGINID"])
        end
      end
    -- user:vlog
    elseif string.match(url, "^https?://m%.xuite%.net/vlog/[0-9A-Za-z._]+$") then
      local user_id = string.match(url, "^https?://m%.xuite%.net/vlog/([0-9A-Za-z._]+)$")
      html = read_file(file)
      -- $(document).on('click','.vloglist-more',function(e){...});
      if string.match(html, "<a class=\"vloglist%-more\" href=\"javascript:void%(0%);\">more</a>") then
        local val_offset = string.match(html, "<input type=\"hidden\" class=\"loaded\" value=\"([0-9]*)\">")
        local val_user = string.match(html, "<input type=\"hidden\" class=\"loadeduser\" value=\"([0-9A-Za-z._]+)\">")
        local val_vt = string.match(html, "<input type=\"hidden\" class=\"loadedvt\" value=\"([01])\">")
        local val_t = string.match(html, "<input type=\"hidden\" class=\"loadedt\" value=\"([a-z]+)\">")
        local val_p = string.match(html, "<input type=\"hidden\" class=\"loadedp\" value=\"([/0-9]*)\">")
        assert(val_offset == "12", val_offset)
        assert(val_user == user_id, val_user)
        assert(val_vt == "0", val_vt)
        assert(val_t == "list", val_t)
        assert(val_p == "", val_p)
        check("https://m.xuite.net/vlog/ajax?apiType=more&offset=12&user=" .. val_user .. "&vt=0&t=list&p=", url)
      elseif not new_locations[url] then
        local count = string.match(html, "<div class=\"vloglist%-Subdirectory\"> <span>.*的影音%(共 ([0-9]+) 則%)</span> </div>")
        if not count or not (tonumber(count) <= 12) then
          print(url)
          abort_item()
        end
      end
      check("https://vlog.xuite.net/" .. user_id .. "/rss.xml")
      check(url .. "?vt=0")
      check(url .. "?vt=1")
    elseif string.match(url, "^https?://m%.xuite%.net/vlog/ajax%?apiType=more&offset=[0-9]+&user=[0-9A-Za-z._]+&vt=0&t=list&p=$") then
      local user_id = string.match(url, "^https?://m%.xuite%.net/vlog/ajax%?apiType=more&offset=[0-9]+&user=([0-9A-Za-z._]+)&vt=0&t=list&p=$")
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ok"] then
        local referer = "https://m.xuite.net/vlog/" .. user_id
        for thumb in string.gmatch(json["data"], "<img src=\"(//vlog%.xuite%.net/media/home[^\"<>]+)\">") do
          check("https:" .. thumb, referer)
        end
        if json["more"] then
          check("https://m.xuite.net/vlog/ajax?apiType=more&offset=" .. string.format("%.0f", json["offset"]) .. "&user=" .. user_id .. "&vt=0&t=list&p=", referer)
        end
      end
    -- user:vlog:playlist
    elseif string.match(url, "^https?://m%.xuite%.net/vlog/[0-9A-Za-z._]+%?vt=1$") then
      local user_id = string.match(url, "^https?://m%.xuite%.net/vlog/([0-9A-Za-z._]+)%?vt=1$")
      html = read_file(file)
      -- $(document).on('click','.vloglist-more',function(e){...});
      -- if string.match(html, "<a class=\"vloglist%-more\" href=\"javascript:void%(0%);\">more</a>") then
      if string.match(html, "class=\"vloglist%-more\"") then
        print("TODO: More playlist button looks like " .. url .. " . Please post this message on the IRC channel #sweet@irc.hackint.org .")
        abort_item()
        if false then
        local val_offset = string.match(html, "<input type=\"hidden\" class=\"loaded\" value=\"([0-9]*)\">")
        local val_user = string.match(html, "<input type=\"hidden\" class=\"loadeduser\" value=\"([0-9A-Za-z._]+)\">")
        local val_vt = string.match(html, "<input type=\"hidden\" class=\"loadedvt\" value=\"([01])\">")
        local val_t = string.match(html, "<input type=\"hidden\" class=\"loadedt\" value=\"([a-z]+)\">")
        local val_p = string.match(html, "<input type=\"hidden\" class=\"loadedp\" value=\"([/0-9]*)\">")
        assert(val_offset == "12", val_offset)
        assert(val_user == user_id, val_user)
        assert(val_vt == "1", val_vt)
        assert(val_t == "list", val_t)
        assert(val_p == "", val_p)
        end
        check("https://m.xuite.net/vlog/ajax?apiType=more&offset=12&user=" .. user_id .. "&vt=1&t=list&p=", url)
      elseif not new_locations[url] then
        local count = string.match(html, "<div class=\"vloglist%-Subdirectory\"> <span>.*的播放清單%(共 ([0-9]+) 則%)</span> </div>")
        -- TODO: what is the playlist offset?
        if tonumber(count) > 10 then
          print("TODO: playlists less than " .. count .. " have no more button. Please post this message on the IRC channel #sweet@irc.hackint.org .")
          abort_item()
        end
      end
      for thumb in string.gmatch(html, "<img src=\"(//vlog%.xuite%.net/media/home[^\"<>]+)\">") do
        check("https:" .. thumb, url)
      end
      for plid in string.gmatch(html, "<a class=\"vloglist%-video%-thumb\" href=\"//vlog%.xuite%.net/_playlist/play%?plid=([0-9]+)\">") do
        discover_item(discovered_data, "playlist," .. plid .. "," .. user_id)
        check("https://vlog.xuite.net/_pub/conf_playlist_v2.php?plid=" .. plid)
        check("https://vlog.xuite.net/flash/playlist?plid=" .. plid)
        check("https://vlog.xuite.net/_playlist/play?plid=" .. plid)
      end
    elseif string.match(url, "^https?://m%.xuite%.net/vlog/ajax%?apiType=more&offset=[0-9]+&user=[0-9A-Za-z._]+&vt=1&t=list&p=$") then
      print("TODO: More playlist AJAX looks like " .. url .. " . Please post this message on the IRC channel #sweet@irc.hackint.org .")
      abort_item()
      local user_id = string.match(url, "^https?://m%.xuite%.net/vlog/ajax%?apiType=more&offset=[0-9]+&user=([0-9A-Za-z._]+)&vt=1&t=list&p=$")
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ok"] then
        -- local referer = "https://m.xuite.net/vlog/" .. user_id .. "?vt=1"
        -- for plid in string.gmatch(json["data"], "<a class=\"vloglist%-video%-thumb\" href=\"//vlog%.xuite%.net/_playlist/play%?plid=([0-9]+)\">") do
        --   discovered_data["pl"][plid] = user_id
        --   check("https://vlog.xuite.net/_pub/conf_playlist_v2.php?plid=" .. plid)
        --   check("https://vlog.xuite.net/flash/playlist?plid=" .. plid)
        --   check("https://vlog.xuite.net/_playlist/play?plid=" .. plid)
        -- end
        -- for thumb in string.gmatch(json["data"], "<img src=\"(//vlog%.xuite%.net/media/home[^\"<>]+)\">") do
        --   check("https:" .. thumb, referer)
        -- end
        -- if json["more"] then
        --   check("https://m.xuite.net/vlog/ajax?apiType=more&offset=" .. string.format("%.0f", json["offset"]) .. "&user=" .. user_id .. "&vt=1&t=list&p=", referer)
        -- end
      end
    elseif string.match(url, "^https?://vlog%.xuite%.net/_playlist/play%?plid=[0-9]+$") then
      local plid = string.match(url, "^https?://vlog%.xuite%.net/_playlist/play%?plid=([0-9]+)$")
      if not new_locations[url] then
        print(url)
        abort_item()
      elseif not string.match(new_locations[url], "^https://my%.xuite%.net/error%.php%?") then
        assert(string.match(new_locations[url], "^https?://vlog%.xuite%.net/play/[0-9A-Za-z=]+%?as=1&list=([0-9]+)$") == plid, new_locations[url])
      end
    elseif string.match(url, "^https?://vlog%.xuite%.net/play/[0-9A-Za-z=]+%?as=1&list=[0-9]+$") then
      local plid = string.match(url, "^https?://vlog%.xuite%.net/play/[0-9A-Za-z=]+%?as=1&list=([0-9]+)$")
      html = read_file(file)
      for vlog_id in string.gmatch(html, "<a class=\"single%-playlist%-video%-thumb%-link\" href=\"/play/([0-9A-Za-z=]+)%?list=[0-9]+\">") do
        check("https://vlog.xuite.net/play/" .. vlog_id .. "?list=" .. plid)
        discover_vlog(vlog_id)
      end
      for uid in string.gmatch(html, "<span class=\"single%-playlist%-video%-author%-label\" >上傳者：</span><a href=\"/([0-9A-Za-z._]+)\" >") do
        discover_user(nil, uid)
      end
    -- user:vlog:directory
    elseif string.match(url, "^https?://m%.xuite%.net/vlog/[0-9A-Za-z._]+%?t=cat&p=/[0-9]+&dir_num=all$") then
      local user_id, p = string.match(url, "^https?://m%.xuite%.net/vlog/([0-9A-Za-z._]+)%?t=cat&p=(/[0-9]+)&dir_num=all$")
      html = read_file(file)
      -- $(document).on('click','.vloglist-more',function(e){...});
      if string.match(html, "<a class=\"vloglist%-more\" href=\"javascript:void%(0%);\">more</a>") then
        local val_offset = string.match(html, "<input type=\"hidden\" class=\"loaded\" value=\"([0-9]*)\">")
        local val_user = string.match(html, "<input type=\"hidden\" class=\"loadeduser\" value=\"([0-9A-Za-z._]+)\">")
        local val_vt = string.match(html, "<input type=\"hidden\" class=\"loadedvt\" value=\"([01])\">")
        local val_t = string.match(html, "<input type=\"hidden\" class=\"loadedt\" value=\"([a-z]+)\">")
        local val_p = string.match(html, "<input type=\"hidden\" class=\"loadedp\" value=\"([/0-9]*)\">")
        assert(val_offset == "12", val_offset)
        assert(val_user == user_id, val_user)
        assert(val_vt == "0", val_vt)
        assert(val_t == "cat", val_t)
        assert(val_p == p, val_p)
        check("https://m.xuite.net/vlog/ajax?apiType=more&offset=12&user=" .. val_user .. "&vt=0&t=cat&p=" .. p, url)
      elseif not new_locations[url] then
        local count = string.match(html, "<div class=\"vloglist%-Subdirectory\"> <span><a href=\"%?vt=0\">.*的影音</a></span><span> %- 資料夾 %[ .* %]%(共 ([0-9]+) 則%)</span> </div>")
        if not count or not (tonumber(count) <= 12) then
          print(url)
          abort_item()
        end
      end
    elseif string.match(url, "^https?://m%.xuite%.net/vlog/ajax%?apiType=more&offset=[0-9]+&user=[0-9A-Za-z._]+&vt=0&t=cat&p=/[0-9]+") then
      local user_id, p = string.match(url, "^https?://m%.xuite%.net/vlog/ajax%?apiType=more&offset=[0-9]+&user=([0-9A-Za-z._]+)&vt=0&t=cat&p=/([0-9]+)")
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ok"] and json["more"] and json["offset"] then
        local referer = "https://m.xuite.net/vlog/" .. user_id .. "?t=cat&p=/" .. p .. "&dir_num=all"
        check("https://m.xuite.net/vlog/ajax?apiType=more&offset=" .. json["offset"] .. "&user=" .. user_id .. "&vt=0&t=cat&p=/" .. p, referer)
      end
    -- user:API
    elseif string.match(url, "^https?://api%.xuite%.net/api%.php%?") then
      local user_id = string.match(url, "&user_id=([0-9A-Za-z._]+)")
      html = read_file(file)
      local success, json = pcall(JSON.decode, JSON, html)
      if not success then
        print("TODO: handle the malformed API response. " .. url)
        abort_item()
      elseif string.match(url, "method=xuite%.blog%.public%.getBlogs&") and json["ok"] then
        for _, blog in pairs(json["rsp"]["blogs"]) do
          assert(string.match(blog["blog_id"], "^[0-9]+$"))
          -- assert(string.match(blog["blog_name"], "^[0-9A-Za-z]+$")) -- accept malformed blog URLs
          discover_blog(user_id, blog["blog_name"], blog["blog_id"])
          if user_sn_tbl[user_id] then
            local sn_hash = md5.sumhexa(user_sn_tbl[user_id])
            for _, asset_name in pairs({ "photo.jpg", "blog.css" }) do
              local sn_prefix = sn_hash:sub(1,1).."/"..sn_hash:sub(2,2).."/"..sn_hash:sub(3,3).."/"..sn_hash:sub(4,4).."/"
              check("https://" .. sn_hash:sub(1,1) .. ".blog.xuite.net/" .. sn_prefix .. user_sn_tbl[user_id] .. "/" .. "blog_" .. blog["blog_id"] .. "/" .. asset_name)
            end
            check("http://blog.xuite.net/_theme/SmallPaintExp.php?mid=" .. user_sn_tbl[user_id] .. "&bid=" .. blog["blog_id"], "https://blog.xuite.net/" .. user_id .. "/" .. blog["blog_name"])
          else
            abort_item()
          end
          check("http://blog.xuite.net/_service/smallpaint/swf/main.swf?server_url=/_users&service_url=/_service/smallpaint/&save_url=/_service/smallpaint/save.php&list_url=/_service/smallpaint/list.php&bid=" .. blog["blog_id"] .. "&author=N")
          check("http://blog.xuite.net/_service/smallpaint/list.php?bid=" .. blog["blog_id"] .. "&ran=0")
          if string.len(blog["thumb"]) >= 1 then
            check(blog["thumb"])
          end
        end
      elseif string.match(url, "method=xuite%.photo%.public%.getAlbums&") and json["ok"] then
        for _, album in pairs(json["rsp"]) do
          if string.match(album["album_id"], "^[0-9]+$") and string.match(album["category_id"], "^[0-9]+$") then
            discover_album(user_id, album["album_id"])
            check("https://photo.xuite.net/_category?st=cat&uid=" .. user_id .. "&sk=" .. album["category_id"])
          else
            abort_item()
          end
        end
      elseif (string.match(url, "method=xuite%.vlog%.public%.getVlogs&") or string.match(url, "method=xuite%.vlog%.public%.getVlogsByDir&")) and json["ok"] then
        local vlogs_n = 0
        for _, _ in pairs(json["rsp"]["vlogs"]) do vlogs_n = vlogs_n + 1 end
        if not (json["rsp"]["total"] == vlogs_n) then
          abort_item()
        end
        for _, vlog in pairs(json["rsp"]["vlogs"]) do
          discover_vlog(vlog["vlog_id"])
        end
      elseif string.match(url, "method=xuite%.vlog%.public%.getDirs&") and json["ok"] then
        if json["rsp"]["total"] == 0 then
          if json["rsp"]["dirs"] then
            abort_item()
          end
        else
          local dirs_n = 0
          for _, _ in pairs(json["rsp"]["dirs"]) do dirs_n = dirs_n + 1 end
          if not (json["rsp"]["total"] == dirs_n) then
            abort_item()
          end
          for _, dir in pairs(json["rsp"]["dirs"]) do
            assert(string.match(dir["dir_id"], "^[0-9]+$"))
            discover_item(discovered_data, "directory," .. dir["dir_id"] .. "," .. user_id)
            check(
              "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
              .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. dir["dir_id"] .. "xuite.vlog.public.getVlogsByDir" .. user_id)
              .. "&method=xuite.vlog.public.getVlogsByDir"
              .. "&user_id=" .. user_id
              .. "&dir_id=" .. dir["dir_id"]
            )
            check("https://m.xuite.net/vlog/" .. user_id .. "?t=cat&p=/" .. dir["dir_id"] .. "&dir_num=all")
          end
        end
      end
    end
  end

  if item_type == "blog" then
    -- blog:pc:view
    if string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z._]+/[0-9A-Za-z]+$")
      or string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z._]+/[0-9A-Za-z]+%?&p=[0-9]+$")
      or string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z._]+/[0-9A-Za-z]+%?st=c&p=[0-9]+&w=[0-9]+$")
      or string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z._]+/[0-9A-Za-z]+%?st=c&w=[0-9]+&p=[0-9]+$") then
      local user_id, blog_url = string.match(url, "^https?://blog%.xuite%.net/([0-9A-Za-z._]+)/([0-9A-Za-z]+)")
      html = read_file(file)
      for embed in string.gmatch(html, "<embed[^<>]*src=\"([^\"<>]+)\"[^<>]*>") do
        if string.match(embed, "//[^/]*xuite%.net/")
          or string.match(embed, "//[^/]*xuite%.com/")
          or string.match(embed, "//[^/]*xuite%.tw/")
          or string.match(embed, "^/[^/]") then
          check(embed)
        end
      end
      -- https://blog.xuite.net/_public/js/blog_01.js TemplateJS.item_main.main()
      local _config = string.match(html, "<script>[^T<>]*TemplateJS%.item_main%.main%(({[^%(%)]+})%)")
      local _config_theme_navigationbar = string.match(html, "<script>[^T<>]*TemplateJS%.theme_navigationbar%.main%(({[^%(%)]+})%)")
      if string.match(html, "<div class=\"blogbody\" style=\"padding%-bottom:15px;\"><img src=\"//blog%.xuite%.net/_image/blog040105%.gif\" width=\"67\" height=\"47\">本日誌尚未新增文章喔！</div>") then
        if _config then
          print("TemplateJS.item_main._config should not appear in empty blog " .. url)
          abort_item()
        elseif not _config_theme_navigationbar then
          print("Cannot find TemplateJS.theme_navigationbar._config from " .. url)
          abort_item()
        else
          _config_theme_navigationbar = JSObj:decode(_config_theme_navigationbar)
          assert(string.match(_config_theme_navigationbar["bid"], "^[0-9]+$"))
        end
      elseif not _config then
        print("Cannot find TemplateJS.item_main._config from " .. url)
        abort_item()
      else
        -- TODO: the modified JavaScript object parser (JSObj.lua) may be unstable
        _config = JSObj:decode(_config)
        assert(_config["burl"] == blog_url)
      end
      local at_root = string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z._]+/[0-9A-Za-z]+$")
      if at_root then
        check(url .. "/mosaic-view")
        check(url .. "/brick-view")
        check(url .. "/snapshot-view")
        check(url .. "/list-view")
        check(url .. "/expert-view")
        check(url .. "/atom.xml")
        check(url .. "/rss.xml")
        -- blog:pc:count 參觀人次統計 function getCountSide(json){}
        if _config then
          check(
            "https://blog.xuite.net/_theme/CountSideExp.php"
            .. "?bid=" .. _config["bid"]
            .. "&ga=" .. TSTAMP
          , url)
        elseif _config_theme_navigationbar then
          check(
            "https://blog.xuite.net/_theme/CountSideExp.php"
            .. "?bid=" .. _config_theme_navigationbar["bid"]
            .. "&ga=" .. TSTAMP
          , url)
        end
      end
      if _config then
        if tonumber(_config["locked_num"]) ~= 0 then
          check(
            "https://blog.xuite.net/_theme/ArticlePasswdExp.php"
            .. "?burl=" .. _config["burl"]
            .. "&list=" .. _config["list_article"]
            .. "&ga=" .. TSTAMP
          , url)
        end
        check(
          "https://blog.xuite.net/_theme/ArticleCounterExp.php"
          .. "?bid=" .. _config["bid"]
          .. "&start=" .. _config["start"]
          .. "&offset=" .. _config["offset"]
          .. "&st=" .. _config["st"]
          .. "&where=" .. _config["where"]
          .. "&mid=" .. _config["mid"]
          .. "&set=" .. _config["set"]
          .. "&ga=" .. TSTAMP
        , url)
      end
      if at_root then
        -- blog:pc:visitor 誰拜訪過我 https://img.xuite.net/xui/combo/w/visitor
        -- this widget can be turned off by the user, causing the visitor_key not to be displayed
        local visitor_key = string.match(html, "\r\n<script>\r\n	var visitor = %$%(\"div%.visitorSide\"%)%.get%(0%);\r\n	new XUI%.Widgets%.Visitor%(visitor, {\r\n        key : '([0-9A-Za-z=]+)'\r\n    }%)%.render%(%);\r\n</script>")
        if visitor_key ~= nil then
          if base64.decode(visitor_key) ~= url:gsub("^https://", "http://") then
            abort_item()
          end
        -- but we can derive the visitor_key ...
        else
          -- remove the second result returned by string.gsub
          visitor_key = url:gsub("^https://", "http://")
          visitor_key = base64.encode(visitor_key)
        end
        check(
          "https://my.xuite.net/api/visitor2xml.php"
          .. "?callback=" .. EXPANDO.."_"..TSTAMP
          .. "&set=15"
          .. "&key=" .. visitor_key
          .. "&_=" .. TSTAMP
        , "https://blog.xuite.net/")
        -- blog:pc:GA4 https://img.xuite.net/xui/combo/w/ga4 XUI.Widgets.GA4(channel, mode, id, content_group_index, content_group_value)
        local site_label = string.match(html, "<script type=\"text/javascript\">%$%.getScript%('/_theme/GAExp%.php%?site_label='%+([0-9]+)%);</script>")
        if site_label then
          -- collect site_label numbers and leave them to URLs
          check("https://blog.xuite.net/_theme/GAExp.php?site_label=" .. site_label, url)
        end
        check(url:gsub("^https?://blog%.xuite%.net/", "https://m.xuite.net/blog/", 1))
      end
    -- blog:pc:visitor
    elseif string.match(url, "^https?://my%.xuite%.net/api/visitor2xml%.php%?") then
      html = read_file(file)
      local json = JSON:decode(string.match(html, "^jQuery[0-9]+_[0-9]+%((.+)%)$"))
      if json["items"] then
        for _, item in pairs(json["items"]) do
          discover_user(item["MEMBERID"], item["LOGINID"])
        end
      end
    -- blog:pc:_theme
    elseif string.match(url, "^https?://blog%.xuite%.net/_theme/ArticleCounterExp%.php%?") then
      local set = string.match(url, "&set=([0-9A-Za-z=]+)")
      if string.len(set) >= 1 then
        html = read_file(file)
        local json = JSON:decode(html)
        local articles = {}
        for _, article in pairs(json) do
          assert(type(article["counter"]) == "number")
          articles[article["article_id"]] = true
        end
        for article in base64.decode(set):gmatch("[0-9]+") do
          assert(articles[article] == true)
        end
      end
    -- not tested as it only returns content when we ever entered the correct password for the article
    elseif string.match(url, "^https?://blog%.xuite%.net/_theme/ArticlePasswdExp%.php%?") then
      local _list = string.match(url, "&list=([0-9,]+)")
      html = read_file(file)
      local json = JSON:decode(html)
      html = ""
      local articles = {}
      for article in _list:gmatch("[0-9]+") do
        articles[article] = true
      end
      if json["check"] ~= "0" then
        for idx = 0, tonumber(json["length"]) - 1 do
          local article = json[string.format("%.0f", idx)]
          assert(articles[article["id"]] == true)
          html = html .. " " .. article["SubContent"]
        end
      end
    -- blog:mobile:view
    elseif string.match(url, "^https?://m%.xuite%.net/blog/[0-9A-Za-z._]+/[0-9A-Za-z]+$") then
      local user_id, blog_url = string.match(url, "^https?://m%.xuite%.net/blog/([0-9A-Za-z._]+)/([0-9A-Za-z]+)$")
      html = read_file(file)
      -- https://m.xuite.net/js/xuite1909181330.js $(".button-load-articles").on("click",function(e){...})
      if string.match(html, "<div class=\"button%-load%-articles xmui%-page%-more%-button\">") then
        local val_userAccount = string.match(html, "<input type=\"hidden\" class=\"userAccount\" value=\"([0-9A-Za-z._]+)\">")
        local val_blogId = string.match(html, "<input type=\"hidden\" class=\"blogId\" value=\"([0-9]+)\">")
        local val_loaded = tonumber(string.match(html, "<input type=\"hidden\" class=\"loaded\" value=\"([0-9]+)\">"))
        local val_total = tonumber(string.match(html, "<input type=\"hidden\" class=\"total\" value=\"([0-9]+)\">"))
        assert(val_userAccount == user_id, val_userAccount)
        assert(val_blogId)
        assert(val_loaded < val_total)
        check("https://m.xuite.net/rpc/blog?method=loadMoreArticles&offset=" .. string.format("%.0f", val_loaded + 1) .. "&userAcct=" .. val_userAccount .. "&blogid=" .. val_blogId, url)
      end
    elseif string.match(url, "^https?://m%.xuite%.net/rpc/blog%?method=loadMoreArticles&offset=[0-9]+&userAcct=[0-9A-Za-z._]+&blogid=[0-9]+$") then
      local offset, user_id, blog_id = string.match(url, "^https?://m%.xuite%.net/rpc/blog%?method=loadMoreArticles&offset=([0-9]+)&userAcct=([0-9A-Za-z._]+)&blogid=([0-9]+)$")
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ok"] then
        if json["rsp"]["articles"]["loaded"] >= 1 then
          assert(json["rsp"]["articles"][string.format("%.0f", json["rsp"]["articles"]["loaded"] - 1)])
          assert(json["rsp"]["articles"][string.format("%.0f", json["rsp"]["articles"]["loaded"])] == nil)
        end
        local blog_url = nil
        for key, article in pairs(json["rsp"]["articles"]) do
          if string.match(key, "^[0-9]+$") then
            local article_id
            assert(string.len(article["url"]) >= 1)
            blog_url, article_id = string.match(article["url"], "^/[0-9A-Za-z._]+/([0-9A-Za-z]+)/([0-9]+)$")
            discover_article(user_id, blog_url, article_id)
            if article["thumb"] ~= "/img/www/locked.png" then
              assert(article["thumb"] and article["thumb2"])
              check(article["thumb2"])
              check(article["thumb"])
            end
          else
            assert(key == "loaded")
          end
        end
        local loaded = (tonumber(offset) - 1) + json["rsp"]["articles"]["loaded"]
        if not json["rsp"]["total"] then
          if json["rsp"]["articles"]["loaded"] ~= 0 then
            abort_item()
          end
        elseif not string.match(json["rsp"]["total"], "^[0-9]+$") then
          abort_item()
        elseif loaded < tonumber(json["rsp"]["total"]) then
          local referer = "https://m.xuite.net/blog/" .. user_id .. "/" .. blog_url
          check("https://m.xuite.net/rpc/blog?method=loadMoreArticles&offset=" .. string.format("%.0f", loaded + 1) .. "&userAcct=" .. user_id .. "&blogid=" .. blog_id, referer)
        end
      end
    end
  end

  if item_type == "blog-api" then
    if string.match(url, "^https?://api%.xuite%.net/api%.php%?") then
      local args = parse_args(url)
      local user_id = args["user_id"]
      local blog_id = args["blog_id"]
      assert(type(user_id) == "string", user_id)
      assert(type(blog_id) == "string", blog_id)
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. blog_id .. "xuite.blog.public.getTopArticle" .. user_id)
        .. "&method=xuite.blog.public.getTopArticle"
        .. "&blog_id=" .. blog_id
        .. "&user_id=" .. user_id
      )
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. blog_id .. "" .. "" .. "" .. "" .. "10" .. "xuite.blog.public.getArticles" .. "" .. "1" .. user_id)
        .. "&method=xuite.blog.public.getArticles"
        .. "&blog_id=" .. blog_id
        .. "&user_id=" .. user_id
        .. "&start=" .. "1"
        .. "&limit=" .. "10"
        .. "&blog_pw="
        .. "&keyword="
        .. "&category_id="
        .. "&date="
        .. "&month="
      )
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. blog_id .. "" .. "xuite.blog.public.getBlogCategories" .. user_id)
        .. "&method=xuite.blog.public.getBlogCategories"
        .. "&blog_id=" .. blog_id
        .. "&user_id=" .. user_id
        .. "&blog_pw="
      )
      html = read_file(file)
      local success, json = pcall(JSON.decode, JSON, html)
      if not success then
        print("TODO: handle the malformed API response. " .. url)
        abort_item()
      elseif string.match(url, "method=xuite%.blog%.public%.getArticles&") and json["ok"] then
        local blog_id = string.match(url, "&blog_id=([0-9]+)")
        local user_id = string.match(url, "&user_id=([0-9A-Za-z._]+)")
        local start = string.match(url, "&start=([0-9]+)")
        local limit = string.match(url, "&limit=([0-9]+)")
        if json["rsp"]["total"] ~= nil then
          assert(string.match(json["rsp"]["total"], "^[0-9]+$"))
          start = tonumber(start)
          if start + 9 < tonumber(json["rsp"]["total"]) then
            start = string.format("%.0f", start + tonumber(limit))
            check(
              "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
              .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. blog_id .. "" .. "" .. "" .. "" .. limit .. "xuite.blog.public.getArticles" .. "" .. start .. user_id)
              .. "&method=xuite.blog.public.getArticles"
              .. "&blog_id=" .. blog_id
              .. "&user_id=" .. user_id
              .. "&start=" .. start
              .. "&limit=" .. limit
              .. "&blog_pw="
              .. "&keyword="
              .. "&category_id="
              .. "&date="
              .. "&month="
            )
          end
        else
          local articles_n = 0
          for _, _ in pairs(json["rsp"]["articles"]) do articles_n = articles_n + 1 end
          assert(articles_n == 0)
        end
        for _, article in pairs(json["rsp"]["articles"]) do
          assert(string.match(article["article_id"], "^[0-9]+$"))
          assert(string.match(article["access"], "^[0-9]$"), "Unknown article access: " .. article["access"])
          local blog_url, article_id = string.match(article["url"], "^http://blog.xuite.net/[0-9A-Za-z._]+/([0-9A-Za-z]+)/([0-9]+)$")
          assert(article_id == article["article_id"])
          discover_article(user_id, blog_url, article_id, blog_id)
          if article["access"] ~= "4" and article["access"] ~= "5" then
            assert(article["thumb"] and article["thumb2"])
            check(article["thumb2"])
            check(article["thumb"])
          end
        end
      end
    end
  end

  if item_type == "article" then
    -- article:pc
    if string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+$")
      or string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+%-[^/?]*$") then
      html = read_file(file)
      if not string.match(html, "^<script>alert%(\"此文章不存在喔!!\"%);")
        and not string.match(html, "^<script language=\"javascript\">\nalert%(\"此文章不存在喔!!\"%);")
        and not string.match(html, "<form name='main' method='post' action='/_theme/item/article_lock%.php'>本文章已受保護, 請輸入密碼才能閱讀本文章: <br/><br/>")
        and not string.match(html, "^<script>alert%(\"此篇文章只開放給作者好友閱讀\"%);") then
        local user_id, blog_url, article_id = string.match(url, "^https?://blog%.xuite%.net/([0-9A-Za-z._]+)/([0-9A-Za-z]+)/([0-9]+)")
        -- $(document).ready(function(){});
        -- function Message(aid,bid,uid,a_author_id,index){}
        -- function TrackBack(aid,b_login,b_url,mid,bid,a_author_id,track_flag,index){}
        local
          Maid,Mbid,Muid,Ma_author_id,
          Taid,Tb_login,Tb_url,Tmid,Tbid,Ta_author_id,Ttrack_flag = string.match(html, "\n<script language=\"javascript\">\n    %$%(document%)%.ready%(function%(%){\n        var index=\"\";\n        Message%(([0-9]+),([0-9]+),([0-9]+),([0-9]+),index%);\n        TrackBack%('([0-9]+)','([0-9A-Za-z._]+)','([0-9A-Za-z]+)','([0-9]+)','([0-9]+)','([0-9]+)','([A-Z]+)',index%);\n")
        if not Ttrack_flag then
          Maid,Mbid,Muid,Ma_author_id,
          Taid,Tb_login,Tb_url,Tmid,Tbid,Ta_author_id,Ttrack_flag = string.match(html, "\n %$%(document%)%.ready%(function%(%){\n   	%$%.ajax%({\n     type: \"GET\",\n     url: '/_theme/ArticleDetailCounterExp%.php%?aid=[0-9]+&ga='%+%(new Date%(%)%)%.getTime%(%),\n     dataType: 'json',\n     success: getArticleDetailCounter\n    }%);\n     \n    var index=\"\";\n    Message%(([0-9]+),([0-9]+),([0-9]+),([0-9]+),index%);  \n    TrackBack%('([0-9]+)','([0-9A-Za-z._]+)','([0-9A-Za-z]+)','([0-9]+)','([0-9]+)','([0-9]+)','([A-Z]+)',index%);  \n")
        end
        -- if (index == "" && location.hash != '#message_header') { mid = location.hash.replace("#",""); }
        local Mmid = ""
        if string.match(html, "<html itemscope=\"itemscope\" itemtype=\"http://schema%.org/Blog\">") then
          if not (Maid and Mbid and Muid and Ma_author_id) then
            print("Cannot find Message() arguments from " .. url)
            abort_item()
          elseif not (Taid and Tb_login and Tb_url and Tmid and Tbid and Ta_author_id and Ttrack_flag) then
            print("Cannot find TrackBack() arguments from " .. url)
            abort_item()
          else
            assert(Maid == Taid)
            assert(Maid == article_id and Taid == article_id)
            assert(Mbid == Tbid)
            assert(Muid == Tmid)
            -- Muid and Ma_author_id may be different, because the blog owner can grant permission to other users to publish articles
            assert(Ma_author_id == Ta_author_id)
            assert(Tb_login == user_id)
            assert(Tb_url == blog_url)
            user_id_tbl[Muid] = user_id
            blog_url_tbl[Mbid] = blog_url
            -- function getArticleDetailCounter(json){}
            check(
              "https://blog.xuite.net/_theme/ArticleDetailCounterExp.php"
              .. "?aid=" .. article_id
              .. "&ga=" .. TSTAMP
            , url)
            check(
              "https://blog.xuite.net/_theme/TrackBackShowExp.php"
              .. "?aid=" .. Taid
              .. "&b_login=" .. Tb_login
              .. "&b_url=" .. Tb_url
              .. "&mid=" .. Tmid
              .. "&bid=" .. Tbid
              .. "&a_author_id=" .. Ta_author_id
              .. "&track_flag=" .. Ttrack_flag
              .. "&index="
              .. "&ga=" .. TSTAMP
            , url)
            check(
              "https://blog.xuite.net/_theme/MessageShowExp.php"
              .. "?ver=new"
              .. "&aid=" .. Maid
              .. "&uid=" .. Muid
              .. "&bid=" .. Mbid
              .. "&a_author_id=" .. Ma_author_id
              .. "&index=" .. "1"
              .. "&mid=" .. Mmid
              .. "&ga=" .. TSTAMP
            , url)
            check(
              "https://blog.xuite.net/_theme/MessageShowExp.php"
              .. "?ver=new"
              .. "&aid=" .. Maid
              .. "&uid=" .. Muid
              .. "&bid=" .. Mbid
              .. "&a_author_id=" .. Ma_author_id
              .. "&index="
              .. "&mid=" .. Mmid
              .. "&ga=" .. TSTAMP
            , url)
          end
        elseif not new_locations[url] then
          print("Unrecognized article response " .. url)
          abort_item()
        end
      end
      if string.match(url, "^https?://blog%.xuite%.net/[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+$") then
        for _, asset_name in pairs({ "cover.jpg", "cover200.jpg", "cover400.jpg", "cover600.jpg" }) do
          check(url .. "/" .. asset_name)
        end
        check(url:gsub("^https?://blog%.xuite%.net/", "https://m.xuite.net/blog/", 1))
      end
    -- article:pc:_theme
    elseif string.match(url, "^https?://blog%.xuite%.net/_theme/ArticleDetailCounterExp%.php%?") then
      local article_id = string.match(url, "%?aid=([0-9]+)")
      html = read_file(file)
      local json = JSON:decode(html)
      assert(type(json[1]["counter"]) == "number")
      assert(json[1]["article_id"] == article_id)
    elseif string.match(url, "^https?://blog%.xuite%.net/_theme/MessageShowExp%.php%?") then
      local user_id = user_id_tbl[string.match(url, "&uid=([0-9]+)")]
      local blog_url = blog_url_tbl[string.match(url, "&bid=([0-9]+)")]
      html = read_file(file)
      local json = JSON:decode(html)
      for aid,bid,uid,a_author_id,index in string.gmatch(json["message"]["content"], "<a href=\"javascript:Message%(([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+)%)\" >") do
        local referer = "https://blog.xuite.net/" .. user_id .. "/" .. blog_url .. "/" .. aid
        check(
          "https://blog.xuite.net/_theme/MessageShowExp.php"
          .. "?ver=new"
          .. "&aid=" .. aid
          .. "&uid=" .. uid
          .. "&bid=" .. bid
          .. "&a_author_id=" .. a_author_id
          .. "&index=" .. index
          .. "&mid="
          .. "&ga=" .. TSTAMP
        , referer)
      end
      html = json["message"]["content"]
    elseif string.match(url, "^https?://blog%.xuite%.net/_theme/TrackBackShowExp%.php%?") then
      local user_id = string.match(url, "&b_login=([0-9A-Za-z._]+)")
      local blog_url = string.match(url, "&b_url=([0-9A-Za-z]+)")
      html = read_file(file)
      local json = JSON:decode(html)
      for aid,b_login,b_url,mid,bid,a_author_id,track_flag,index in string.gmatch(json["trackBack"]["content"], "<a href=\"javascript:TrackBack%(([0-9]+),'([0-9A-Za-z._]+)','([0-9A-Za-z]+)',([0-9]+),([0-9]+),([0-9]+),'([A-Z]+)',([0-9]+)%)\" >") do
        local referer = "https://blog.xuite.net/" .. user_id .. "/" .. blog_url .. "/" .. aid
        check(
          "https://blog.xuite.net/_theme/TrackBackShowExp.php"
          .. "?aid=" .. aid
          .. "&b_login=" .. b_login
          .. "&b_url=" .. b_url
          .. "&mid=" .. mid
          .. "&bid=" .. bid
          .. "&a_author_id=" .. a_author_id
          .. "&track_flag=" .. track_flag
          .. "&index=" .. index
          .. "&ga=" .. TSTAMP
        , referer)
      end
      html = json["trackBack"]["content"]
    -- article:mobile
    elseif string.match(url, "^https?://m%.xuite%.net/blog/[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+$") then
      local user_id, article_id = string.match(url, "^https?://m%.xuite%.net/blog/([0-9A-Za-z._]+)/[0-9A-Za-z]+/([0-9]+)$")
      html = read_file(file)
      if string.match(html, "<link rel=\"canonical\" href=\"//blog%.xuite%.net/[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+\" />") then
        if not string.match(html, "<form class=\"secret%-form\" data%-ajax=\"false\" method=\"POST\" > <section id=\"secret%-form%-container\"> <input id=\"secret%-password\" type=\"password\" name=\"pwInput\" placeholder=\"請輸入密碼\" value=\"\" data%-role=\"none\" autocomplete=\"off\"/>")
          and not string.match(html, "<h1 id=\"noauth%-h1\">你沒有瀏覽權限</h1>") then
          if string.match(html, "<div class=\"xmui%-page%-more\" style=\"display:none\">") then
            -- https://m.xuite.net/js/channel1705081030.js if(g.target.id==="blog-show")a("#blog-show-load-comments",d).on("click",function(){a.xuite.ajaxLoadComment(...)}).click();
            local val_cmmtArg = string.match(html, "<input type=\"hidden\" class=\"cmmtArg\" value=\"([^\"<>]*)\"/>")
            if string.len(val_cmmtArg) >= 1 then
              local userAccount, blogid, articleid = string.match(val_cmmtArg, "^blog,([^\"<>]+),([^\"<>]+),([^\"<>]+)$")
              local data_comment_page = string.match(html, "<div id=\"blog%-show%-load%-comments\" class=\"xmui%-page%-more%-button\" data%-comment%-page=([0-9]+) data%-loaded=0>")
              -- local data_commenttotal = tonumber(string.match(html, "<span id=\"commentNum\" data%-commenttotal=\"([0-9]+)\">[0-9%+]+</span>"))
              assert(userAccount == user_id)
              assert(articleid == article_id)
              assert(data_comment_page == "1")
              check("https://m.xuite.net/rpc/blog?method=loadComment&userAccount=" .. userAccount .. "&blogid=" .. blogid .. "&articleid=" .. articleid .. "&p=1", url)
            end
          elseif not new_locations[url] then
            print("Unrecognized article response " .. url)
            abort_item()
          end
        end
      end
    elseif string.match(url, "^https?://m%.xuite%.net/rpc/blog%?method=loadComment&userAccount=[0-9A-Za-z._]+&blogid=[0-9]+&articleid=[0-9]+&p=[0-9]+$") then
      -- p>=2 is broken (rpc always returns p=1)
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ok"] then
        if json["rsp"]["total"] == 0 then
          if json["rsp"]["comment"] then
            abort_item()
          end
        else
          for _, comment in pairs(json["rsp"]["comment"]) do
            if comment["login_type"] == "cht" then
              local sn = string.match(comment["sn"], "^[0-9]+$")
              local uid = string.match(comment["user_id"], "^[0-9A-Za-z._]+$")
              if sn and uid then
                discover_user(sn, uid)
              else
                abort_item()
              end
            end
            if comment["reply"] then
              local sn = string.match(comment["reply"]["sn"], "^[0-9]+$")
              local uid = string.match(comment["reply"]["user_id"], "^[0-9A-Za-z._]+$")
              if sn and uid then
                discover_user(sn, uid)
              else
                abort_item()
              end
            end
          end
        end
      end
    end
  end

  if item_type == "article-api" then
    if string.match(url, "^https?://api%.xuite%.net/api%.php%?") then
      local args = parse_args(url)
      local user_id = args["user_id"]
      local blog_id = args["blog_id"]
      local article_id = args["article_id"]
      assert(type(user_id) == "string", user_id)
      assert(type(blog_id) == "string", blog_id)
      assert(type(article_id) == "string", article_id)
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. article_id .. "" .. blog_id .. "" .. "xuite.blog.public.getArticle" .. user_id)
        .. "&method=xuite.blog.public.getArticle"
        .. "&blog_id=" .. blog_id
        .. "&user_id=" .. user_id
        .. "&article_id=" .. article_id
        .. "&blog_pw="
        .. "&article_pw="
      )
    end
  end

  if item_type == "album" then
    -- album:list
    if string.match(url, "^https?://m%.xuite%.net/photo/[0-9A-Za-z._]+/[0-9]+$") then
      local user_id, album_id = string.match(url, "^https?://m%.xuite%.net/photo/([0-9A-Za-z._]+)/([0-9]+)$")
      html = read_file(file)
      -- $(document).on('click','.photolist-more',function(e){...});
      if string.match(html, "<a class=\"photolist%-more\" href=\"javascript:void%(0%);\">more</a>") then
        local val_userId = string.match(html, "<input type=\"hidden\" class=\"userId\" value=\"([0-9A-Za-z._]+)\">")
        local val_albumId = string.match(html, "<input type=\"hidden\" class=\"albumId\" value=\"([0-9]+)\">")
        local data_cnt = string.match(html, "<div class=\"xmui%-page%-more\" data%-cnt=\"([0-9]*)\">")
        assert(val_userId == user_id, val_userId)
        assert(val_albumId == album_id, val_albumId)
        assert(data_cnt == "24", data_cnt)
        check("https://m.xuite.net/rpc/photo?method=loadPhotos&userId=" .. val_userId .. "&albumId=" .. val_albumId .. "&limit=24&offset=24", url)
      elseif not new_locations[url] then
        local count = string.match(html, "<div class=\"photolist%-Subdirectory\"> <span>個人相簿＞.*%(共([0-9]+)張%)</span><a href=\"/photo/[0-9A-Za-z._]+\">回相簿列表</a> </div>")
        if not count or not (tonumber(count) <= 24) then
          print(url)
          abort_item()
        end
      end
      -- before wget discovers the first 24 photos, we must explicitly pass them to check()
      -- otherwise, we have no chance to append the header ["Cookie"] = "exif=1"
      for photo_suffix in string.gmatch(html, "<a class=\"photolist%-photo%-thumb\" href=\"/photo(/[0-9A-Za-z._]+/[0-9]+/[0-9]+)\" data%-pos=\"[0-9]+\">") do
        check("https://m.xuite.net/photo" .. photo_suffix)
        -- the above URL 302 redirects to the following URL, so the following URL must be also explicitly passed to check()
        check("https://photo.xuite.net" .. photo_suffix .. ".jpg")
      end
      check("https://photo.xuite.net/_feed/photo?user_id=" .. user_id .. "&album_id=" .. album_id .. "&count=-1")
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. album_id .. xuite_api_key .. "500" .. "xuite.photo.public.getPhotos" .. "" .. "0" .. user_id)
        .. "&method=xuite.photo.public.getPhotos"
        .. "&user_id=" .. user_id
        .. "&album_id=" .. album_id
        .. "&pw="
        .. "&start=" .. "0"
        .. "&limit=" .. "500"
      )
      check(url:gsub("^https?://m%.xuite%.net/photo/", "https://photo.xuite.net/", 1))
    elseif string.match(url, "^https?://photo%.xuite%.net/_feed/photo%?user_id=[0-9A-Za-z._]+&album_id=[0-9]+&count=%-?[0-9]+$") then
      local user_id, album_id, count = string.match(url, "^https?://photo%.xuite%.net/_feed/photo%?user_id=([0-9A-Za-z._]+)&album_id=([0-9]+)&count=(%-?[0-9]+)$")
      html = read_file(file)
      local json = JSON:decode(html)
      if json["error"] == nil then
        local photos_n = 0
        for _, _ in pairs(json["photos"]) do photos_n = photos_n + 1 end
        if not (json["user_id"] == user_id and json["album_id"] == album_id) then
          print(url, json["user_id"], json["album_id"])
          abort_item()
        elseif tonumber(count) <= 0 then
          if not (tonumber(json["total"]) == photos_n or (tonumber(json["total"]) >= 2000 and photos_n == 2000)) then
            print(url, json["total"], photos_n)
            abort_item()
          end
        elseif not (tonumber(count) >= photos_n) then
          print(url, json["total"], photos_n)
          abort_item()
        end
      end
    elseif string.match(url, "^https?://m%.xuite%.net/rpc/photo%?method=loadPhotos&userId=[0-9A-Za-z._]+&albumId=[0-9]+&limit=24&offset=[0-9]+$") then
      local user_id, album_id, offset = string.match(url, "^https?://m%.xuite%.net/rpc/photo%?method=loadPhotos&userId=([0-9A-Za-z._]+)&albumId=([0-9]+)&limit=24&offset=([0-9]+)$")
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ok"] and json["_ismore"] then
        local photos_n = 0
        for _, _ in pairs(json["rsp"]["photos"]) do photos_n = photos_n + 1 end
        local referer = "https://m.xuite.net/photo/" .. user_id .. "/" .. album_id
        check("https://m.xuite.net/rpc/photo?method=loadPhotos&userId=" .. user_id .. "&albumId=" .. album_id ..  "&limit=24&offset=" .. string.format("%.0f", tonumber(offset) + photos_n), referer)
      end
    -- album:API
    elseif string.match(url, "^https?://api%.xuite%.net/api%.php%?") then
      html = read_file(file)
      local json = JSON:decode(html)
      if string.match(url, "method=xuite%.photo%.public%.getPhotos&") and json["ok"] then
        local user_id = string.match(url, "&user_id=([0-9A-Za-z._]+)")
        local album_id = string.match(url, "&album_id=([0-9]+)")
        local start = string.match(url, "&start=([0-9]+)")
        local photos_n = 0
        for _, photo in pairs(json["rsp"]["photos"]) do
          if not string.match(photo["position"], "^[0-9]+$") then
            print("Cannot find photo position from " .. url, photo["position"])
            abort_item()
          else
            local referer = "https://m.xuite.net/photo/" .. user_id .. "/" .. album_id
            check("https://m.xuite.net/photo/" .. user_id .. "/" .. album_id .. "/" .. photo["position"], referer)
            check("https://photo.xuite.net/" .. user_id .. "/" .. album_id .. "/" .. photo["position"] .. ".jpg", "https://m.xuite.net/")
          end
          photos_n = photos_n + 1
        end
        if tonumber(json["rsp"]["total"]) > tonumber(start) + 500 and photos_n >= 1 then
          start = string.format("%.0f", tonumber(start) + 500)
          check(
            "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
            .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. album_id .. xuite_api_key .. "500" .. "xuite.photo.public.getPhotos" .. "" .. start .. user_id)
            .. "&method=xuite.photo.public.getPhotos"
            .. "&user_id=" .. user_id
            .. "&album_id=" .. album_id
            .. "&pw="
            .. "&start=" .. start
            .. "&limit=" .. "500"
          )
        end
      end
    end
  end

  if item_type == "photo" then
    if string.match(url, "^https?://photo%.xuite%.net/[0-9A-Za-z._]+/[0-9]+/[0-9]+%.jpg$") then
      local user_id, album_id, serial = string.match(url, "^https?://photo%.xuite%.net/([0-9A-Za-z._]+)/([0-9]+)/([0-9]+)%.jpg$")
      html = read_file(file)
      for uid in string.gmatch(html, "<a class=\"single%-comment%-user%-name\" href=\"//photo%.xuite%.net/([0-9A-Za-z._]+)\" target=\"_blank\" >") do
        discover_user(nil, uid)
      end
      local img_prefix, img_suffix = string.match(html, "<img class=\"single%-show%-image \" src=\"(https://[0-9a-f]%.share%.photo%.xuite%.net/[0-9A-Za-z._]+/[0-9a-f]+/[0-9]+/[0-9]+_)[xlmstqQ](%.[^.\"]+)\" alt=\"[^<>]*\"></div>")
      if not img_prefix or not img_suffix then
        img_prefix, img_suffix = string.match(html, "<img class=\"single%-show%-image fixed\" src=\"(https://[0-9a-f]%.share%.photo%.xuite%.net/[0-9A-Za-z._]+/[0-9a-f]+/[0-9]+/[0-9]+_)[xlmstqQ](%.[^.\"]+)\" alt=\"[^<>]*\"></div>")
      end
      local picture_id = nil
      if img_prefix then
        picture_id = string.match(img_prefix, "https://[0-9a-f]%.share%.photo%.xuite%.net/[0-9A-Za-z._]+/[0-9a-f]+/[0-9]+/([0-9]+)_")
      end
      -- string.match(html, "<div style=\"margin:10px 0;\">本相簿內容已受保護，請輸入密碼：</div>")
      if not new_locations[url] then
        if not (img_prefix and img_suffix and picture_id) then
          print(url)
          abort_item()
        end
      end
      -- first in first out
      if img_prefix and img_suffix then
        -- check(img_prefix .. "o" .. img_suffix, "https://photo.xuite.net/")
        -- check(img_prefix .. "t" .. img_suffix, "https://photo.xuite.net/")
      end
      -- check(url .. "/sizes/t/", url .. "/sizes/o/")
      -- if img_prefix and img_suffix then
      --   check(img_prefix .. "s" .. img_suffix, "https://photo.xuite.net/")
      -- end
      -- check(url .. "/sizes/s/", url .. "/sizes/o/")
      -- if img_prefix and img_suffix then
      --   check(img_prefix .. "m" .. img_suffix, "https://photo.xuite.net/")
      -- end
      -- check(url .. "/sizes/m/", url .. "/sizes/o/")
      -- if img_prefix and img_suffix then
      --   check(img_prefix .. "l" .. img_suffix, "https://photo.xuite.net/")
      -- end
      -- check(url .. "/sizes/l/", url .. "/sizes/o/")
      if img_prefix and img_suffix then
        check(img_prefix .. "x" .. img_suffix, "https://photo.xuite.net/")
      end
      check(url .. "/sizes/x/", url .. "/sizes/o/")
      check(url .. "/sizes/o/", url)
      if img_prefix and img_suffix then
        check(img_prefix .. "q" .. img_suffix, "https://photo.xuite.net/")
        check(img_prefix .. "Q" .. img_suffix, "https://photo.xuite.net/")
      end
      -- https://photo.xuite.net/javascripts/picture_single.comb.js $("#single-more #single-more-title").click(); $.post()
      -- Although Cookie exif=1 is set to get the Exif included in the HTML, we also make this POST request
      if string.match(html, "<div id=\"single%-more%-title\" ><a href=\"javascript:;\" >更多相片資訊</a></div>") and not string.match(html, "<div id=\"single%-more\"  style=\"display:none\">") and picture_id then
        table.insert(urls, {
          url="https://photo.xuite.net/_picinfo/exif",
          headers={ ["Origin"] = "https://photo.xuite.net", ["Referer"] = url, ["X-Requested-With"] = "XMLHttpRequest" },
          post_data="picture_id=" .. picture_id .. "&user_id=" .. user_id
        })
      end
      check("https://m.xuite.net/photo/" .. user_id .. "/" .. album_id .. "/" .. serial)
    elseif string.match(url, "^https?://photo%.xuite%.net/[0-9A-Za-z._]+/[0-9]+/[0-9]+%.jpg/sizes/o/$") then
      html = read_file(file)
      if not new_locations[url] then
        local img_orig = string.match(html, "<a href=\"[^\"<>]+\"><img src=\"(//o%.[0-9a-f]%.photo%.xuite%.net/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9A-Za-z._]+/[0-9]+/[0-9]+%.[^.\"]+)\" alt=\"\" class=\"[^\"<>]*\"></a>")
        if img_orig then
          -- must be requested with a valid referrer header!
          check("https:" .. img_orig, "https://photo.xuite.net/")
        else
          print("Could not find the original resolution of the photo. " .. url)
          abort_item()
        end
      end
    end
  end

  if item_type == "vlog" then
    -- vlog:pc
    if string.match(url, "^https?://vlog%.xuite%.net/play/[0-9A-Za-z=]+$") then
      local vlog_id = string.match(url, "^https?://vlog%.xuite%.net/play/([0-9A-Za-z=]+)$")
      assert(vlog_id == item_value)
      -- local media_id = string.match(base64.decode(vlog_id), "%-([0-9]+)%.[0-9a-z]+$")
      html = read_file(file)
      if string.match(html, "<meta name=\"medium\" content=\"video\" />") then
        local media_info = string.match(html, "\n    <script>\n        var mediaInfo = ({[^\n]+});\n        var pageInfo = {[^\n]+};\n")
        if media_info then
          local json = JSON:decode(media_info)
          -- assert(json["MEDIA_TYPE"] == "1" or json["MEDIA_TYPE"] == "2")
          -- assert(json["base64FileName"] == vlog_id)
          -- assert(json["MEDIA_ID"] == media_id)
          for _, key in pairs({ "html5HQUrl2", "html5HQUrl", "html5Url" }) do
            if string.len(json[key]) >= 1 then
              if not string.match(json[key], "^//[^/]") then
                print(key .. " is malformed (" .. json[key] .. ") in " .. url)
                abort_item()
              else
                check("https:" .. json[key], "https://vlog.xuite.net/")
              end
            end
          end
          if string.len(json["thumbSBX"]) >= 1 then check("https:" .. json["thumbSBX"], url) end
          if string.len(json["ogImageUrl"]) >= 1 then check(json["ogImageUrl"], url) end
          if string.len(json["thumbnailUrl"]) >= 1 then check("https:" .. json["thumbnailUrl"], url) end
          if json["MEDIA_TYPE"] == "1" then
            check("https://vlog.xuite.net/flash/audioplayer?media=" .. base64.encode(json["MEDIA_ID"]))
          end
          check("https://vlog.xuite.net/flash/player?media=" .. base64.encode(json["MEDIA_ID"]))
          check("https://vlog.xuite.net/_api/media/playcheck/media/" .. base64.encode(json["MEDIA_ID"]))
        else
          print("Cannot find mediaInfo from " .. url)
          abort_item()
        end
      else
        if not string.match(html, "<h1 id=\"message%-title\">Xuite 影音錯誤訊息</h1>") then
          abort_item()
        end
      end
      check(
        "https://api.xuite.net/api.php?api_key=" .. xuite_api_key
        .. "&api_sig=" .. md5.sumhexa(xuite_secret_key .. xuite_api_key .. "xuite.vlog.public.getVlog" .. "" .. "vlog" .. vlog_id)
        .. "&method=xuite.vlog.public.getVlog"
        .. "&vlog_id=" .. vlog_id
        .. "&passwd="
        .. "&site=" .. "vlog"
      )
      -- check("https://m.xuite.net/vlog/" .. user_id .. "/" .. item_value)
      check("https://vlog.xuite.net/embed/" .. item_value)
    elseif string.match(url, "^https?://vlog%.xuite%.net/_api/media/playcheck/media/[0-9A-Za-z=]+$")
      or string.match(url, "^https?://vlog%.xuite%.net/_api/media/playcheck/media/[0-9A-Za-z=]+/pwd/[0-9]+$")
      or string.match(url, "^https?://vlog%.xuite%.net/flash/player%?media=[0-9A-Za-z=]+$")
      or string.match(url, "^https?://vlog%.xuite%.net/flash/audioplayer%?media=[0-9A-Za-z=]+$") then
      html = read_file(file)
      local handler = xmlhandler:new()
      xml2lua.parser(handler):parse(html)
      local properties = {}
      for _, property in pairs(handler.root["flv-config"]["property"]) do
        properties[base64.decode(property["_attr"]["id"])] = urlcode.unescape(base64.decode(property[1]))
      end
      for _, key in pairs({ "logo", "author_blog", "author_picture", "thumb", "url" }) do
        if properties[key] and string.len(properties[key]) >= 1 then
          check(properties[key]:gsub("^//", "https://"):gsub("^http://", "https://"))
        end
      end
      for _, key in pairs({ "hd1080_src", "hq_src", "flv_src", "src" }) do
        if properties[key] and string.len(properties[key]) >= 1 then
          assert(string.match(properties[key], "^//[0-9a-f]%.mms%.vlog%.xuite%.net/"))
          check("https:" .. properties[key], "https://vlog.xuite.net/")
        end
      end
      -- tprint(properties)
    -- vlog:mobile
    elseif string.match(url, "^https?://m%.xuite%.net/vlog/[0-9A-Za-z._]+/[0-9A-Za-z=]+$") then
      local user_id, vlog_id = string.match(url, "^https?://m%.xuite%.net/vlog/([0-9A-Za-z._]+)/([0-9A-Za-z=]+)$")
      assert(vlog_id == item_value)
      html = read_file(file)
      if string.match(html, "<div id=\"vlog%-item\">") then
        -- https://m.xuite.net/js/channel1705081030.js else g.target.id==="vlog-show"&&a.xuite.ajaxLoadComment(...)
        local val_cmmtArg = string.match(html, "<input type=\"hidden\" class=\"cmmtArg\" value=\"([^\"<>]*)\"/>")
        if string.len(val_cmmtArg) >= 1 then
          local userAccount, vlogId = string.match(val_cmmtArg, "^vlog,([^\"<>]+),([^\"<>]+)$")
          if userAccount == user_id and vlogId == vlog_id then
            check("https://m.xuite.net/rpc/vlog?method=loadComment&userAccount=" .. userAccount .. "&vlogId=" .. vlogId:gsub("=", "%%3D"), url)
          else
            abort_item()
          end
        end
      end
    elseif string.match(url, "^https?://m%.xuite%.net/rpc/vlog%?method=loadComment&userAccount=[0-9A-Za-z._]+&vlogId=[0-9A-Za-z=%%]+$") then
      html = read_file(file)
      local json = JSON:decode(html)
      if json["ok"] then
        for _, comment in pairs(json["rsp"]["comment"]) do
          if comment["login_type"] == "cht" then
            local sn = string.match(comment["sn"], "^[0-9]+$")
            local uid = string.match(comment["user_id"], "^[0-9A-Za-z._]+$")
            if sn and uid then
              discover_user(sn, uid)
            else
              abort_item()
            end
          end
          if comment["reply"] then
            local sn = string.match(comment["reply"]["sn"], "^[0-9]+$")
            local uid = string.match(comment["reply"]["user_id"], "^[0-9A-Za-z._]+$")
            if sn and uid then
              discover_user(sn, uid)
            else
              abort_item()
            end
          end
        end
      end
    -- vlog:file
    elseif string.match(url, "^https?://[0-9a-f]%.mms%.vlog%.xuite%.net/.+$") then
      -- Let URL-agnostic deduplication happens
      -- local vlog_suffix = string.match(url, "^https?://[0-9a-f]%.mms%.vlog%.xuite%.net/(.+)$")
      -- for i = 15, 0, -1 do
      --   check(string.format("https://%x.mms.vlog.xuite.net/", i) .. vlog_suffix)
      -- end
    end
  end

  if item_type == "pic-thumb" then
    if string.match(url, "^https?://pic%.xuite%.net/thumb/") then
      local orig_url = string.match(url, "^https?://pic%.xuite%.net/thumb/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]+/([0-9A-Za-z=]+)/[0-9A-Za-z]+%.jpg$")
      if not orig_url then
        orig_url = string.match(url, "^https?://pic%.xuite%.net/thumb/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]+/([0-9A-Za-z=]+)_[0-9A-Za-z=]+/[0-9A-Za-z]+%.jpg$")
      end
      if orig_url then
        check(base64.decode(#orig_url % 4 == 2 and (orig_url .. '==') or #orig_url % 4 == 3 and (orig_url .. '=') or orig_url))
      else
        print("Unknown thumb URL " .. url)
        abort_item()
      end
    end
  end

  if item_type == "keyword" then
    if string.match(url, "^https?://m%.xuite%.net/rpc/search%?") then
      local method = string.match(url, "%?method=([a-z]+)")
      local kw = string.match(url, "&kw=([^%?&=]+)")
      local offset = tonumber(string.match(url, "&offset=([0-9]+)"))
      local limit = tonumber(string.match(url, "&limit=([0-9]+)"))
      check("https://m.xuite.net/rpc/search?method=vlog&kw=" .. kw .. "&offset=1&limit=30")
      check("https://m.xuite.net/rpc/search?method=blog&kw=" .. kw .. "&offset=1&limit=30")
      if string.match(kw, "^[0-9A-Za-z._]+$") then
        check("https://m.xuite.net/rpc/search?method=account&kw=" .. kw .. "&offset=1&limit=30")
      end
      check("https://m.xuite.net/rpc/search?method=nickname&kw=" .. kw .. "&offset=1&limit=30")
      html = read_file(file)
      local json = JSON:decode(html)
      if json and json["ok"] then
        if type(json["rsp"]) == "table" then
          local items_n = 0
          for _, _ in pairs(json["rsp"]["items"]) do items_n = items_n + 1 end
          if method == "blog" or method == "vlog" then
            if json["rsp"]["_ismore"] == true then
              assert(limit == items_n - 1)
              check(
                "https://m.xuite.net/rpc/search?method=" .. method
                .. "&kw=" .. kw
                .. "&offset=" .. string.format("%.0f", offset + limit)
                .. "&limit=" .. string.format("%.0f", limit)
              )
            elseif not (items_n == 0 or offset + items_n - 2 == json["rsp"]["total"]) then
              abort_item()
            end
            if offset == 1 then
              print("Found " .. string.format("%.0f", json["rsp"]["total"]) .. " " .. (method == "blog" and "articles" or "vlogs"))
            end
          elseif method == "account" or method == "nickname" then
            assert(json["rsp"]["count"] >= items_n - 1 and items_n >= 1)
            if json["rsp"]["count"] == 30 and limit == 30 then
              for _ = 1, 20 do
                -- results vary with the limit
                check(
                  "https://m.xuite.net/rpc/search?method=" .. method
                  .. "&kw=" .. kw
                  .. "&offset=1"
                  .. "&limit=" .. string.format("%.0f", math.random(31, 2147483647)) -- math.random(31, 9223372036854775807) Lua 5.3
                )
              end
            end
          else
            print("Unknown search method " .. method)
            abort_item()
          end
          assert(type(json["rsp"]["items"]) == "table")
          for _, item in pairs(json["rsp"]["items"]) do
            if item["type"] == nil then
              if method == "blog" then
                assert(string.match(item["img"], "^//avatar%.xuite%.tw/[0-9]+/s$"))
                assert(string.match(item["link"], "^/blog/[0-9A-Za-z._]+/[0-9A-Za-z]+/[0-9]+$"))
                check("https:" .. item["img"])
                check("https://m.xuite.net" .. item["link"])
              elseif method == "vlog" then
                assert(string.match(item["link"], "^/vlog/[0-9A-Za-z._]+/[0-9A-Za-z=]+$"))
                assert(string.match(item["vlog_id"], "^[0-9A-Za-z=]+$"))
                check("https://m.xuite.net" .. item["link"])
                discover_vlog(item["vlog_id"])
              elseif method == "account" or method == "nickname" then
                assert(item["sn"] and item["uid"])
                local sn = string.match(item["sn"], "^[0-9]+$")
                local uid = string.match(item["uid"], "^[0-9A-Za-z._]+$")
                if sn and uid then
                  discover_user(sn, uid)
                else
                  local item_name = string.format("%.0f", item["sn"]) .. ":" .. urlcode.escape(item["uid"])
                  print("Ignore malformed user " .. item_name)
                  discover_item(discovered_data, "user-malformed:" .. item_name)
                end
              end
            elseif not (item["type"] == "hot" and item["sn"] == nil and item["uid"] == nil) then
              abort_item()
            end
          end
        elseif not (type(json["rsp"]) == "boolean" and json["rsp"] == false) then
          abort_item()
        end
      end
    end
  end

  if item_type == "embed" then
    local args = parse_args(url)
    local argc = 0
    for _, _ in pairs(args) do argc = argc + 1 end
    -- 相簿Slideshow
    if string.match(url, "^https?://blog%.xuite%.net/_service/swf/pageshow%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/pageshowA%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/sideslideshow%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/sideslideshowA%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/sideslideshowB%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/sideslideshowM%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/sideslideshowMB%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/sideslideshowN%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/slideshow%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/slideshowA%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/slideshowNB%.swf%?")
      or string.match(url, "^https?://blog%.xuite%.net/_service/swf/slideshowMM%.swf%?")
      or string.match(url, "^https?://photo%.xuite%.net/images/player/slide_xuite%.swf%?") then
      if (type(args["id"]) == "string" or type(args["user_id"]) == "string") and (type(args["album"]) == "string" or type(args["album_id"]) == "string") then
        local user_id = args["id"] or args["user_id"]
        local album_id = args["album"] or args["album_id"]
        discover_album(user_id, album_id)
      else
        abort_item()
      end
    -- 變身錄音筆
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/djshow/swf/main%.swf%?") then
      if not (
            type(args["xml_url"]) == "string"
        and args["server_url"] == "/_users"
        and args["service_url"] == "/_service/djshow/"
        and args["face_swf_url"] == "/_service/face2"
        and type(args["mp3path"]) == "string"
        and type(args["txtpath"]) == "string"
        and args["act"] == "show"
        and type(args["face_url"]) == "string"
        and argc == 8
      ) then
        abort_item()
      end
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/djshow/swf/action/.+%.swf$")
      or string.match(url, "^https?://blog%.xuite%.net/_service/djshow/swf/front/.+%.swf$")
      or string.match(url, "^https?://blog%.xuite%.net/_service/djshow/swf/templet/.+%.swf$") then
      -- do nothing
    -- 自拍相片本
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/slideshow/swf/main%.swf%?") then
      if not (
            type(args["xml_url"]) == "string"
        and args["server_url"] == "/_users"
        and args["service_url"] == "/_service/slideshow/"
        and type(args["ImageUrl"]) == "string"
        and args["act"] == "show"
        and argc == 5
      ) then
        abort_item()
      end
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/slideshow/swf/templet/.+%.swf$") then
      -- do nothing
    -- 愛秀投影機
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/mtv/swf/main%.swf%?") then
      if not (
            type(args["xml_url"]) == "string"
        and args["server_url"] == "/_users"
        and args["service_url"] == "/_service/mtv/"
        and type(args["ImageUrl"]) == "string"
        and type(args["SoundUrl"]) == "string"
        and args["act"] == "show"
        and argc == 6
      ) then
        abort_item()
      end
    -- 快速變臉筆
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/snap/swf/main%.swf%?") then
      if not (
            type(args["xml_url"]) == "string"
        and args["server_url"] == "/_users"
        and args["service_url"] == "/_service/snap/"
        and type(args["ImageUrl"]) == "string"
        and args["act"] == "show"
        and argc == 5
      ) then
        abort_item()
      end
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/snap/swf/templet/.+%.swf$") then
      -- do nothing
    -- 手寫塗鴉版
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/paint/swf/show%.swf%?") then
      if not (
            type(args["xml_url"]) == "string"
        and args["server_url"] == "/_users"
        and args["service_url"] == "/_service/paint/"
        and args["act"] == "show"
        and argc == 4
      ) then
        abort_item()
      end
    -- 留言塗鴉版
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/smallpaint/swf/main%.swf%?") then
      if not (
            args["server_url"] == "/_users"
        and args["service_url"] == "/_service/smallpaint/"
        and args["save_url"] == "/_service/smallpaint/save.php"
        and args["list_url"] == "/_service/smallpaint/list.php"
        and type(args["bid"]) == "string" and string.match(args["bid"], "^[0-9]+$")
        and (args["author"] == "Y" or args["author"] == "N")
        and argc == 6
      ) then
        abort_item()
      end
    -- 電視牆
    elseif string.match(url, "^https?://blog%.xuite%.net/_service/wall/swf/main%.swf%?") then
      if not (
            type(args["xml_url"]) == "string"
        and args["server_url"] == "/_users"
        and args["service_url"] == "/_service/wall/"
        and args["act"] == "show"
        and ((type(args["nocache"]) == "string" and argc == 5) or (type(args["nocache"]) == "nil" and argc == 4))
      ) then
        abort_item()
      end
    elseif string.match(url, "^https?://vlog%.xuite%.net/vlog/swf/audio_player%.swf%??[^?]*$")
      or string.match(url, "^https?://vlog%.xuite%.net/vlog/swf/index_player%.swf%??[^?]*$")
      or string.match(url, "^https?://vlog%.xuite%.net/vlog/swf/lite%.swf%??[^?]*$")
      or string.match(url, "^https?://vlog%.xuite%.net/vlog/swf/mPlayer%.swf%??[^?]*$")
      or string.match(url, "^https?://vlog%.xuite%.net/vlog/swf/mPlayer2%.swf%??[^?]*$") then
      -- do nothing
    else
      print("TODO: unknown embedded SWF file: " .. url)
      abort_item()
    end
    local check_assetUrl = function(url)
      -- assert(string.match(url, "^https?://[0-9a-f]%.blog%.xuite%.net/")
      --   or string.match(url, "^https?://mms%.blog%.xuite%.net/")
      --   or string.match(url, "^https?://[0-9a-f]%.mms%.blog%.xuite%.net/"), url)
      check(url)
    end
    if type(args["xml_url"]) == "string" then
      if string.match(args["xml_url"], "^/.+/flash_config%.xml$") or string.match(args["xml_url"], "^https?://[0-9a-f]%.blog%.xuite%.net/.+/flash_config%.xml$") then
        check(urlparse.absolute("http://blog.xuite.net/", args["xml_url"]))
      else
        abort_item()
      end
    end
    if type(args["face_url"]) == "string" then
      if string.match(args["face_url"], "^/.+/face%.xml$") or string.match(args["face_url"], "^https?://[0-9a-f]%.blog%.xuite%.net/.+/face%.xml$") then
        check(urlparse.absolute("http://blog.xuite.net/", args["face_url"]))
      else
        abort_item()
      end
    end
    if type(args["ImageUrl"]) == "string" then
      for image in string.gmatch(args["ImageUrl"], "[^,]+") do
        check_assetUrl(image)
      end
    end
    for _, arg_name in pairs({ "SoundUrl", "mp3path", "txtpath" }) do
      if type(args[arg_name]) == "string" then
        if select(2, args[arg_name]:gsub(",", ",")) == 0 then
          if string.len(args[arg_name]) >= 1 then
            check_assetUrl(args[arg_name])
          end
        else
          abort_item()
        end
      end
    end
  end

  if item_type == "asset" then
    if string.match(url, "^http://[0-9a-f]%.blog%.xuite%.net/") then
      check(url:gsub("^http://[0-9a-f]%.blog%.xuite%.net/", "http://blog.xuite.net/_users/", 1))
      check(url:gsub("%.blog%.xuite%.net/", ".mms.blog.xuite.net/", 1))
    end
    if string.match(url, "^http://[^/]*blog%.xuite%.net/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]/")
      or string.match(url, "^http://blog%.xuite%.net/_users/[0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f]/") then
      local sn_hash = string.match(url, "^http://[^/]*blog%.xuite%.net/([0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f])/") or string.match(url, "^http://blog%.xuite%.net/_users/([0-9a-f]/[0-9a-f]/[0-9a-f]/[0-9a-f])/")
      check(url:gsub(sn_hash, sn_hash:sub(1,1)..sn_hash:sub(3,3).."/"..sn_hash:sub(5,5)..sn_hash:sub(7,7), 1))
    end
    if string.match(url, "^https?://[0-9a-f]%.share%.photo%.xuite%.net/[0-9A-Za-z._]+/[0-9a-f]+/[0-9]+/[0-9]+_[oxlmstqQ]%.[^.\"]+$") then
      local img_prefix, img_suffix = string.match(url, "^(https?://[0-9a-f]%.share%.photo%.xuite%.net/[0-9A-Za-z._]+/[0-9a-f]+/[0-9]+/[0-9]+_)[oxlmstqQ](%.[^.\"]+)$")
      -- check(img_prefix .. "o" .. img_suffix, "https://photo.xuite.net/")
      -- check(img_prefix .. "t" .. img_suffix, "https://photo.xuite.net/")
      -- check(img_prefix .. "s" .. img_suffix, "https://photo.xuite.net/")
      -- check(img_prefix .. "m" .. img_suffix, "https://photo.xuite.net/")
      -- check(img_prefix .. "l" .. img_suffix, "https://photo.xuite.net/")
      check(img_prefix .. "x" .. img_suffix, "https://photo.xuite.net/")
      check(img_prefix .. "q" .. img_suffix, "https://photo.xuite.net/")
      check(img_prefix .. "Q" .. img_suffix, "https://photo.xuite.net/")
    end
    if string.match(url, "%.xml$") and not new_locations[url] then
      html = read_file(file)
      if not string.match(html, "<title>Xuite 提示訊息</title>") and not string.match(html, "<h1 id=\"message%-title\">此網頁不存在</h1>") then
        local handler = xmlhandler:new()
        xml2lua.parser(handler):parse(html)
        if string.match(url, "blog_[0-9]+/djshow/[0-9]+/flash_config%.xml$") then
          -- assert(handler.root["AAAOE"]["AEB"]["aface_XML"])
          if handler.root["AAAOE"]["AEB"]["O_PP"]["_attr"] then
            check(urlparse.absolute("http://blog.xuite.net/_service/djshow/", handler.root["AAAOE"]["AEB"]["O_PP"]["_attr"]["O_FP"]))
          else
            for _, O_PP in pairs(handler.root["AAAOE"]["AEB"]["O_PP"]) do
              check(urlparse.absolute("http://blog.xuite.net/_service/djshow/", O_PP["_attr"]["O_FP"]))
            end
          end
          if type(handler.root["AAAOE"]["AEB"]["MP3_XML"]["_attr"]["Mp3_FP"]) == "string" then
            check(urlparse.absolute("http://blog.xuite.net/_service/djshow/", handler.root["AAAOE"]["AEB"]["MP3_XML"]["_attr"]["Mp3_FP"]))
          end
          if type(handler.root["AAAOE"]["AEB"]["voice_XML"]["_attr"]["voice_tx"]) == "string" and handler.root["AAAOE"]["AEB"]["voice_XML"]["_attr"]["voice_tx"] ~= "text_filename" then
            check(urlparse.absolute("http://blog.xuite.net/_service/djshow/", handler.root["AAAOE"]["AEB"]["voice_XML"]["_attr"]["voice_tx"]))
          end
          if type(handler.root["AAAOE"]["AEB"]["voice_XML"]["_attr"]["voice_fn"]) == "string" and handler.root["AAAOE"]["AEB"]["voice_XML"]["_attr"]["voice_fn"] ~= "voice_filename" then
            check(urlparse.absolute("http://blog.xuite.net/_service/djshow/", handler.root["AAAOE"]["AEB"]["voice_XML"]["_attr"]["voice_fn"]))
          end
        elseif string.match(url, "blog_[0-9]+/slideshow/[0-9]+/flash_config%.xml$") then
          if handler.root["SS"]["A_XML"]["P_XML"] then
            if handler.root["SS"]["A_XML"]["P_XML"]["_attr"] then
              check(handler.root["SS"]["A_XML"]["P_XML"]["_attr"]["P_FP"])
            else
              for _, P_XML in pairs(handler.root["SS"]["A_XML"]["P_XML"]) do
                check(P_XML["_attr"]["P_FP"])
              end
            end
          end
          if type(handler.root["SS"]["AAAOE"]["AEB"]["O_PP"]["_attr"]["O_FP"]) == "string" then
            check(urlparse.absolute("http://blog.xuite.net/_service/slideshow/", handler.root["SS"]["AAAOE"]["AEB"]["O_PP"]["_attr"]["O_FP"]))
          end
          if type(handler.root["SS"]["AAAOE"]["AEB"]["MP3_XML"]["_attr"]["Mp3_FP"]) == "string" then
            check(urlparse.absolute("http://blog.xuite.net/_service/slideshow/", handler.root["SS"]["AAAOE"]["AEB"]["MP3_XML"]["_attr"]["Mp3_FP"]))
          end
        elseif string.match(url, "blog_[0-9]+/mtv/[0-9]+/flash_config%.xml$") then
          if not (handler.root["NSS"]["SHOW_XML"] and handler.root["NSS"]["MP3_XML"]) then
            abort_item()
          end
        elseif string.match(url, "blog_[0-9]+/snap/[0-9]+/flash_config%.xml$") then
          if handler.root["SNAP"]["templetData"]["back"] then
            if type(handler.root["SNAP"]["templetData"]["back"]["NA_P"]["_attr"]["FP"]) == "string" then
              check(urlparse.absolute("http://blog.xuite.net/_service/snap/", handler.root["SNAP"]["templetData"]["back"]["NA_P"]["_attr"]["FP"]))
            end
            if type(handler.root["SNAP"]["templetData"]["back"]["NA_T"]["_attr"]["FP"]) == "string" then
              check(urlparse.absolute("http://blog.xuite.net/_service/snap/", handler.root["SNAP"]["templetData"]["back"]["NA_T"]["_attr"]["FP"]))
            end
            if type(handler.root["SNAP"]["templetData"]["back"]["MP3_XML"]["_attr"]["FP"]) == "string" then
              check(urlparse.absolute("http://blog.xuite.net/_service/snap/", handler.root["SNAP"]["templetData"]["back"]["MP3_XML"]["_attr"]["FP"]))
            end
          end
        elseif string.match(url, "blog_[0-9]+/paint/[0-9]+/flash_config%.xml$") then
          if not handler.root["DRAWDATA"]["PAINT"] then
            abort_item()
          end
        elseif string.match(url, "blog_[0-9]+/tvwall/flash_config%.xml$") then
          if handler.root["WALL"]["PHO"] then
            if handler.root["WALL"]["PHO"]["_attr"] then
              check(urlparse.absolute("http://blog.xuite.net/", handler.root["WALL"]["PHO"]["_attr"]["P_UR"]))
            else
              for _, PHO in pairs(handler.root["WALL"]["PHO"]) do
                check(urlparse.absolute("http://blog.xuite.net/", PHO["_attr"]["P_UR"]))
              end
            end
          end
        elseif string.match(url, "/flash_config%.xml$") then
          print("Unrecognized occurrence of flash_config.xml " .. url)
          abort_item()
        elseif string.match(url, "blog_[0-9]+/smallpaint/[0-9]+%.xml$") then
          if not handler.root["DRAWDATA"]["PAINT"] then
            abort_item()
          end
        elseif string.match(url, "/[0-9]+/face%.xml$") then
          for key, obj in pairs(handler.root["MYPLAY"]) do
            if key ~= "_attr" then
              if type(obj["_attr"]["E_UR"]) == "string" and string.len(obj["_attr"]["E_UR"]) >= 1 then
                if string.match(obj["_attr"]["E_UR"], "^swf/[^/%.%?&=]+%.swf") then
                  check(urlparse.absolute("http://blog.xuite.net/_service/face2/", obj["_attr"]["E_UR"]))
                else
                  abort_item()
                end
              end
            end
          end
        else
          print("Unrecognized occurrence of XML file " .. url)
          abort_item()
        end
      end
    end
  end

  if allowed(url)
    and status_code < 300
    -- avoid parsing binaries
    and not string.match(url, "^https?://[0-9a-f]%.blog%.xuite%.net/")
    and not string.match(url, "^https?://[0-9a-f]%.mms%.blog%.xuite%.net/")
    and not string.match(url, "^https?://[0-9a-f]%.photo%.xuite%.net/")
    and not string.match(url, "^https?://o%.[0-9a-f]%.photo%.xuite%.net/")
    and not string.match(url, "^https?://[0-9a-f]%.share%.photo%.xuite%.net/")
    and not string.match(url, "^https?://[0-9a-f]%.mms%.vlog%.xuite%.net/") then
    local is_html = false
    if html == nil then
      html = read_file(file)
    end
    if string.match(url, "^https?://blog%.xuite%.net/_theme/ArticlePasswdExp%.php%?")
      or string.match(url, "^https?://blog%.xuite%.net/_theme/MessageShowExp%.php%?")
      or string.match(url, "^https?://blog%.xuite%.net/_theme/TrackBackShowExp%.php%?") then
      is_html = true
    elseif string.match(url, "^https?://api%.xuite%.net/api%.php%?") and string.match(url, "method=xuite%.blog%.public%.getArticle&") then
      html = flatten_json(JSON:decode(html))
      is_html = true
    end
    if is_html then
      for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
        checknewurl(newurl)
      end
      for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
        checknewurl(newurl)
      end
      for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
        checknewurl(newurl)
      end
      html = string.gsub(html, "&gt;", ">")
      html = string.gsub(html, "&lt;", "<")
      for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
        checknewurl(newurl)
      end
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  local status_code = http_stat["statcode"]
  local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  if status_code >= 500 and tries >= 2 and string.match(url["url"], "^https?://[0-9a-f]%.share%.photo%.xuite%.net/") then
    -- photo thumbnails
    abort_item()
  elseif status_code == 500 or string.match(newloc, "^https?://my%.xuite%.net/error%.php%?ecode=500$") or string.match(newloc, "^https?://my%.xuite%.net/error%.php%?channel=vlog&ecode=500$")
    or status_code == 502 or string.match(newloc, "^https?://my%.xuite%.net/error%.php%?ecode=502$") then
    retry_url = true
    return false
  end
  -- no need to save known error pages that have been saved thousands of times
  if string.match(url["url"], "^https?://my%.xuite%.net/error%.php%?") then
    local err_url = url["url"]
    if string.match(err_url, "%?ecode=403$")
      or string.match(err_url, "%?ecode=404$")
      or string.match(err_url, "%?ecode=500$")
      or string.match(err_url, "%?ecode=502$")
      or string.match(err_url, "%?channel=www&ecode=404$")
      or string.match(err_url, "%?channel=www&ecode=NoAccount$")
      or string.match(err_url, "%?channel=www&ecode=Nodata$")
      or string.match(err_url, "%?channel=blog&ecode=UserDefine&status=404&title=Xuite日誌錯誤訊息&info=此日誌開放設定為被隱藏!!$")
      or string.match(err_url, "%?channel=blog&ecode=UserDefine&status=404&title=Xuite%%E6%%97%%A5%%E8%%AA%%8C%%E9%%8C%%AF%%E8%%AA%%A4%%E8%%A8%%8A%%E6%%81%%AF&info=%%E6%%AD%%A4%%E6%%97%%A5%%E8%%AA%%8C%%E9%%96%%8B%%E6%%94%%BE%%E8%%A8%%AD%%E5%%AE%%9A%%E7%%82%%BA%%E8%%A2%%AB%%E9%%9A%%B1%%E8%%97%%8F!!$")
      or string.match(err_url, "%?channel=blog&ecode=UserDefine&status=404&title=Xuite日誌錯誤訊息&info=文章不存在$")
      or string.match(err_url, "%?channel=blog&ecode=UserDefine&status=404&title=Xuite%%E6%%97%%A5%%E8%%AA%%8C%%E9%%8C%%AF%%E8%%AA%%A4%%E8%%A8%%8A%%E6%%81%%AF&info=%%E6%%96%%87%%E7%%AB%%A0%%E4%%B8%%8D%%E5%%AD%%98%%E5%%9C%%A8$")
      or string.match(err_url, "%?channel=blog&ecode=UserDefine&status=404&title=Xuite日誌錯誤訊息&info=資料錯誤$")
      or string.match(err_url, "%?channel=blog&ecode=UserDefine&status=404&title=Xuite%%E6%%97%%A5%%E8%%AA%%8C%%E9%%8C%%AF%%E8%%AA%%A4%%E8%%A8%%8A%%E6%%81%%AF&info=%%E8%%B3%%87%%E6%%96%%99%%E9%%8C%%AF%%E8%%AA%%A4$")
      or string.match(err_url, "%?channel=photo&ecode=UserDefine&title=Xuite相簿訊息&info=這本相簿不存在或為不公開相簿喔!!$")
      or string.match(err_url, "%?channel=photo&ecode=UserDefine&title=Xuite%%E7%%9B%%B8%%E7%%B0%%BF%%E8%%A8%%8A%%E6%%81%%AF&info=%%E9%%80%%99%%E6%%9C%%AC%%E7%%9B%%B8%%E7%%B0%%BF%%E4%%B8%%8D%%E5%%AD%%98%%E5%%9C%%A8%%E6%%88%%96%%E7%%82%%BA%%E4%%B8%%8D%%E5%%85%%AC%%E9%%96%%8B%%E7%%9B%%B8%%E7%%B0%%BF%%E5%%96%%94!!$")
      or string.match(err_url, "%?channel=photo&ecode=UserDefine&title=Xuite相簿訊息&info=沒這張照片喔!!$")
      or string.match(err_url, "%?channel=photo&ecode=UserDefine&title=Xuite%%E7%%9B%%B8%%E7%%B0%%BF%%E8%%A8%%8A%%E6%%81%%AF&info=%%E6%%B2%%92%%E9%%80%%99%%E5%%BC%%B5%%E7%%85%%A7%%E7%%89%%87%%E5%%96%%94!!$")
      or string.match(err_url, "%?channel=vlog&ecode=500$")
      or string.match(err_url, "%?channel=vlog&ecode=UserDefine&title=Xuite影音錯誤訊息&info=抱歉，您瀏覽的影音不存在或為不公開!!$")
      or string.match(err_url, "%?channel=vlog&ecode=UserDefine&title=Xuite%%E5%%BD%%B1%%E9%%9F%%B3%%E9%%8C%%AF%%E8%%AA%%A4%%E8%%A8%%8A%%E6%%81%%AF&info=%%E6%%8A%%B1%%E6%%AD%%89%%EF%%BC%%8C%%E6%%82%%A8%%E7%%80%%8F%%E8%%A6%%BD%%E7%%9A%%84%%E5%%BD%%B1%%E9%%9F%%B3%%E4%%B8%%8D%%E5%%AD%%98%%E5%%9C%%A8%%E6%%88%%96%%E7%%82%%BA%%E4%%B8%%8D%%E5%%85%%AC%%E9%%96%%8B!!$")
      or string.match(err_url, "%?channel=yo&ecode=UserDefine&title=參數錯誤&info=參數錯誤$")
      or string.match(err_url, "%?channel=yo&ecode=UserDefine&title=%%E5%%8F%%83%%E6%%95%%B8%%E9%%8C%%AF%%E8%%AA%%A4&info=%%E5%%8F%%83%%E6%%95%%B8%%E9%%8C%%AF%%E8%%AA%%A4$") then
      return false
    -- vlog file session key has expired
    elseif string.match(err_url, "%?channel=vlog&ecode=UserDefine&title=Xuite影音錯誤訊息&info=影音認證碼錯誤$")
      or string.match(err_url, "%?channel=vlog&ecode=UserDefine&title=Xuite%%E5%%BD%%B1%%E9%%9F%%B3%%E9%%8C%%AF%%E8%%AA%%A4%%E8%%A8%%8A%%E6%%81%%AF&info=%%E5%%BD%%B1%%E9%%9F%%B3%%E8%%AA%%8D%%E8%%AD%%89%%E7%%A2%%BC%%E9%%8C%%AF%%E8%%AA%%A4$") then
      abort_item()
    end
  -- the article must belong to one of the four scenarios
  elseif string.match(url["url"], "^https?://blog%.xuite%.net/[0-9A-Za-z.][0-9A-Za-z._]*/[0-9A-Za-z]+/?[^/%.%?&=]*$") then
    local html = read_file(http_stat["local_file"])
    if status_code == 200
      and not string.match(html, "<html itemscope=\"itemscope\" itemtype=\"http://schema%.org/Blog\">")
      and not string.match(html, "^<script>alert%(\"此文章不存在喔!!\"%);")
      and not string.match(html, "^<script language=\"javascript\">\nalert%(\"此文章不存在喔!!\"%);")
      and not string.match(html, "<form name='main' method='post' action='/_theme/item/article_lock%.php'>本文章已受保護, 請輸入密碼才能閱讀本文章: <br/><br/>")
      and not string.match(html, "^<script>alert%(\"此篇文章只開放給作者好友閱讀\"%);") then
      retry_url = true
      return false
    elseif status_code == 302 then
      print("The blog/article URL " .. url["url"] .. " redirects to " .. newloc)
    end
  -- must be valid JSON
  elseif string.match(url["url"], "^https?://api%.xuite%.net/api%.php%?")
    or (string.match(url["url"], "^https?://blog%.xuite%.net/_theme/[A-Za-z]+%.php%?") and not string.match(url["url"], "^https?://blog%.xuite%.net/_theme/SmallPaintExp%.php%?"))
    or string.match(url["url"], "^https?://m%.xuite%.net/rpc/search%?")
    or string.match(url["url"], "^https?://m%.xuite%.net/rpc/blog%?method=loadMoreArticles&")
    or string.match(url["url"], "^https?://m%.xuite%.net/rpc/blog%?method=loadComment&")
    or string.match(url["url"], "^https?://m%.xuite%.net/rpc/photo%?method=loadAlbums&")
    or string.match(url["url"], "^https?://m%.xuite%.net/rpc/photo%?method=loadPhotos&")
    or string.match(url["url"], "^https?://m%.xuite%.net/rpc/vlog%?method=loadComment&")
    or string.match(url["url"], "^https?://m%.xuite%.net/vlog/ajax%?apiType=more&")
    or string.match(url["url"], "^https?://photo%.xuite%.net/_feed/album%?")
    or string.match(url["url"], "^https?://photo%.xuite%.net/_feed/photo%?")
    or string.match(url["url"], "^https?://photo%.xuite%.net/_friends$")
    or string.match(url["url"], "^https?://photo%.xuite%.net/@tag_lib_js$") then
    if status_code == 200 then
      local html = read_file(http_stat["local_file"])
      local success, json = pcall(JSON.decode, JSON, html)
      if not success or json == nil then
        retry_url = true
        return false
      end
      if string.match(url["url"], "^https?://m%.xuite%.net/rpc/search%?") then
        if (json and json["ok"] == false and json["msg"] == "Read timed out after 10 seconds") then
          print(html)
          retry_url = true
          return false
        end
        if string.match(url["url"], "%?method=account") and json and json["ok"] == true then
          if type(json["rsp"]) == "table" then
            local items_n = 0
            for _, _ in pairs(json["rsp"]["items"]) do items_n = items_n + 1 end
            return items_n >= 2
          elseif not (type(json["rsp"]) == "boolean" and json["rsp"] == false) then
            return false
          end
        else
          return false
        end
      end
    elseif status_code == 302 then
      print("The response should be JSON instead of " .. newloc)
      retry_url = true
      return false
    elseif status_code == 403 then
      return true
    end
  -- must be valid callback
  elseif string.match(url["url"], "^https?://my%.xuite%.net/service/account/api/external/sn_name%.php%?")
    or string.match(url["url"], "^https?://blog%.xuite%.net/_theme/member_data%.php%?")
    or string.match(url["url"], "^https?://my%.xuite%.net/api/visitor2xml%.php%?") then
    if status_code == 302 then
      print("The response should be JSON instead of " .. newloc)
    end
    if status_code ~= 200 then
      retry_url = true
      return false
    end
  elseif string.match(url["url"], "^https?://mms%.blog%.xuite%.net/") then
    return false
  -- cannot be 302
  elseif string.match(url["url"], "^https?://[0-9a-f]%.share%.photo%.xuite%.net/[0-9A-Za-z._]+/[0-9a-f]+/[0-9]+/[0-9]+_o%.[^.\"]+$") and status_code == 302 then
    if newloc == "http://photo.xuite.net/static/images/logo/not_thumb_o.png" then
      abort_item()
    else
      print(url["url"], newloc)
      abort_item()
    end
  elseif string.match(url["url"], "^https?://o%.[0-9a-f]%.photo%.xuite%.net/") and status_code == 302 then
    if string.match(newloc, "^https?://my%.xuite%.net/error%.php%?ecode=403$") then
      retry_url = true
      return false
    else
      print(newloc)
      abort_item()
    end
  -- some thumbnails always return 503
  elseif string.match(url["url"], "^https?://pic%.xuite%.net/thumb/") and status_code == 503 then
    return false
  -- no need to save "photo.xuite.net/_category?sn=...$"
  elseif string.match(url["url"], "^https?://photo%.xuite%.net/_category%?sn=[0-9]+$") then
    return false
  elseif string.match(url["url"], "^https?://api%.xuite%.net/oembed/%?url=")
    and status_code == 500
    and read_file(http_stat["local_file"]) == "Error!!!: Unknown Video..." then
    return false
  elseif status_code == 504 then
    io.stdout:write("Server gateway timeout:" .. url["url"] .. "\n")
    io.stdout:flush()
    retry_url = true
    return false
  elseif status_code ~= 200
    and status_code ~= 301
    and status_code ~= 302
    and status_code ~= 404 then
    retry_url = true
    return false
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    new_locations[url["url"]] = newloc
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  if status_code < 400 then
    downloaded[url["url"]] = true
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    if string.match(url["url"], "^https?://mms%.blog%.xuite%.net/") then
      io.stdout:write("Ignore mms.blog.xuite.net.\n")
      io.stdout:flush()
      return wget.actions.EXIT
    end
    io.stdout:write("Server returned bad response.")
    io.stdout:flush()
    tries = tries + 1
    if tries > 5 then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write(" Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 10
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and JSON:decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()

  for key, data in pairs({
    ["xuite-tvkqxccsx12r6p6r"] = discovered_items,
    ["xuite-data-sxl4wzibk75ebw5l"] = discovered_data,
    ["urls-1xz0wiu8vhh66k9q"] = discovered_outlinks
  }) do
    print('queuing for', string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 100 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end


