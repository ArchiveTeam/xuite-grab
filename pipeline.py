# encoding=utf8
import datetime
from distutils.version import StrictVersion
import hashlib
import os.path
import random
import re
from seesaw.config import realize, NumberConfigValue
from seesaw.externalprocess import ExternalProcess
from seesaw.item import ItemInterpolation, ItemValue
from seesaw.task import SimpleTask, LimitConcurrent
from seesaw.tracker import GetItemFromTracker, PrepareStatsForTracker, \
    UploadWithTracker, SendDoneToTracker
import shutil
import socket
import subprocess
import sys
import time
import string

import seesaw
from seesaw.externalprocess import WgetDownload
from seesaw.pipeline import Pipeline
from seesaw.project import Project
from seesaw.util import find_executable

from tornado import httpclient

import requests
import zstandard

if StrictVersion(seesaw.__version__) < StrictVersion('0.8.5'):
    raise Exception('This pipeline needs seesaw version 0.8.5 or higher.')

import base64
import urllib.parse

class xuite_api():
    API_KEY = base64.b64decode('NTAwZTQwYjg2MjM5NWQ4YTE3N2Q0MDJkNDNjZWU5ZGI=').decode()
    SECRET_KEY = base64.b64decode('OTk1NzkxNjYzNQ==').decode()
    # switch to another if CHT bans one
    # API_KEY = base64.b64decode('N2IyZWExNWUwNDA5ZDJmOTdhZDJiODg3YjNhOGUxN2I=').decode() # com.x---e.music
    # SECRET_KEY = base64.b64decode('OTMyMDQzNDMyOQ==').decode()
    # API_KEY = base64.b64decode('YTlhNWM4NDRkZjkyZTYzMjM3OTQ4MWY4M2E3YjBlOWQ=').decode() # com.x---e.myX---e
    # SECRET_KEY = base64.b64decode('NDk0ODI2OTU1MQ==').decode()

    @staticmethod
    def api_sig(params: dict, api_key: str = API_KEY, secret_key: str = SECRET_KEY) -> str:
        assert isinstance(params, dict) and isinstance(api_key, str) and isinstance(secret_key, str)
        assert len(api_key) == 32 and len(secret_key) == 10
        # Building a list of dictionary values, sorted by key https://stackoverflow.com/a/36634885
        return hashlib.md5((''.join([secret_key, *[v for _, v in sorted({**params, 'api_key': api_key}.items())]])).encode()).hexdigest()

    @staticmethod
    def api_url(api_parameters: dict) -> str:
        assert isinstance(api_parameters, dict) and isinstance(api_parameters['method'], str) and api_parameters['method'].startswith('xuite.')
        parameters = [
            ('api_key', xuite_api.API_KEY),
            ('api_sig', xuite_api.api_sig(api_parameters)),
        ]
        for key, value in api_parameters.items():
            if key not in ['api_key', 'api_sig']:
                parameters.append((key, value))
        return f"https://api.xuite.net/api.php?{urllib.parse.urlencode(parameters)}"

    # @staticmethod
    # def bf():
    #     for i in range(0000000000, 9999999999+1):
    #         secret_key = f"{i:010d}"
    #         if xuite_api.api_sig({'method': 'xuite.my.public.getEventAngel'}, xuite_api.API_KEY, secret_key) == 'a7b0fa8822011ea0eec59eec2d07e20c':
    #             print(secret_key)
    #             return secret_key

# class xuite_api_slide():
#     # http://blog.xuite.net/_service/swf/pageshow.swf
#     @staticmethod
#     def api_check(mylogin_id: str, myalbum_id: int, weekday_offset: int = None) -> str:
#         assert isinstance(mylogin_id, str) and isinstance(myalbum_id, int)
#         ab = f"{mylogin_id}/{myalbum_id}"
#         if weekday_offset not in range(1, 8):
#             weekday_offset = datetime.datetime.now(tz=datetime.timezone(datetime.timedelta(hours=8))).isoweekday()
#         letter_idx = (myalbum_id + weekday_offset) % 7
#         letter = ab[letter_idx] if letter_idx < len(ab) else ''
#         hashstr = hashlib.md5(f"{myalbum_id}{letter}{mylogin_id}".encode()).hexdigest()
#         idx1 = random.randrange(0, 12)
#         idx2 = random.randrange(16, 28)
#         check = f"{idx1:02}{idx2:02}{hashstr[idx1:idx1+3]}{hashstr[idx2:idx2+3]}"
#         assert re.search(r'^[0-9a-f]{10}$', check)
#         return check

#     @staticmethod
#     def api_url(mylogin_id: str, myalbum_id: int, myalbum_count: int = 10000, weekday_offset: int = None) -> str:
#         assert isinstance(mylogin_id, str) and isinstance(myalbum_id, int) and isinstance(myalbum_count, int)
#         parameters = urllib.parse.urlencode([
#             ('key', f"{mylogin_id}/{myalbum_id}"),
#             ('count', str(myalbum_count)),
#             ('check', xuite_api_slide.api_check(mylogin_id, myalbum_id, weekday_offset)),
#         ], safe='/')
#         return f"https://photo.xuite.net/@api_slide?{parameters}"

###########################################################################
# Find a useful Wget+Lua executable.
#
# WGET_AT will be set to the first path that
# 1. does not crash with --version, and
# 2. prints the required version string

WGET_AT = find_executable(
    'Wget+AT',
    [
        'GNU Wget 1.21.3-at.20230623.01'
    ],
    [
        './wget-at',
        '/home/warrior/data/wget-at-gnutls'
    ]
)

if not WGET_AT:
    raise Exception('No usable Wget+At found.')


###########################################################################
# The version number of this pipeline definition.
#
# Update this each time you make a non-cosmetic change.
# It will be added to the WARC files and reported to the tracker.
VERSION = '20230820.01'
USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36'
TRACKER_ID = 'xuite'
TRACKER_HOST = 'legacy-api.arpa.li'
MULTI_ITEM_SIZE = 1


###########################################################################
# This section defines project-specific tasks.
#
# Simple tasks (tasks that do not need any concurrency) are based on the
# SimpleTask class and have a process(item) method that is called for
# each item.
class CheckIP(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'CheckIP')
        self._counter = 0

    def process(self, item):
        # NEW for 2014! Check if we are behind firewall/proxy

        if self._counter <= 0:
            item.log_output('Checking IP address.')
            ip_set = set()

            ip_set.add(socket.gethostbyname('twitter.com'))
            #ip_set.add(socket.gethostbyname('facebook.com'))
            ip_set.add(socket.gethostbyname('youtube.com'))
            ip_set.add(socket.gethostbyname('microsoft.com'))
            ip_set.add(socket.gethostbyname('icanhas.cheezburger.com'))
            ip_set.add(socket.gethostbyname('archiveteam.org'))

            if len(ip_set) != 5:
                item.log_output('Got IP addresses: {0}'.format(ip_set))
                item.log_output(
                    'Are you behind a firewall/proxy? That is a big no-no!')
                raise Exception(
                    'Are you behind a firewall/proxy? That is a big no-no!')

        # Check only occasionally
        if self._counter <= 0:
            self._counter = 10
        else:
            self._counter -= 1


class PrepareDirectories(SimpleTask):
    def __init__(self, warc_prefix):
        SimpleTask.__init__(self, 'PrepareDirectories')
        self.warc_prefix = warc_prefix

    def process(self, item):
        item_name = item['item_name']
        item_name_hash = hashlib.sha1(item_name.encode('utf8')).hexdigest()
        escaped_item_name = item_name_hash
        dirname = '/'.join((item['data_dir'], escaped_item_name))

        if os.path.isdir(dirname):
            shutil.rmtree(dirname)

        os.makedirs(dirname)

        item['item_dir'] = dirname
        item['warc_file_base'] = '-'.join([
            self.warc_prefix,
            item_name_hash,
            time.strftime('%Y%m%d-%H%M%S')
        ])

        open('%(item_dir)s/%(warc_file_base)s.warc.zst' % item, 'w').close()

class MoveFiles(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'MoveFiles')

    def process(self, item):
        os.rename('%(item_dir)s/%(warc_file_base)s.warc.zst' % item,
              '%(data_dir)s/%(warc_file_base)s.%(dict_project)s.%(dict_id)s.warc.zst' % item)

        shutil.rmtree('%(item_dir)s' % item)


class SetBadUrls(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'SetBadUrls')

    def process(self, item):
        item['item_name_original'] = item['item_name']
        items = item['item_name'].split('\0')
        items_lower = [s.lower() for s in items]
        with open('%(item_dir)s/%(warc_file_base)s_bad-items.txt' % item, 'r') as f:
            for aborted_item in f:
                aborted_item = aborted_item.strip().lower()
                index = items_lower.index(aborted_item)
                item.log_output('Item {} is aborted.'.format(aborted_item))
                items.pop(index)
                items_lower.pop(index)
        item['item_name'] = '\0'.join(items)


class MaybeSendDoneToTracker(SendDoneToTracker):
    def enqueue(self, item):
        if len(item['item_name']) == 0:
            return self.complete_item(item)
        return super(MaybeSendDoneToTracker, self).enqueue(item)


def get_hash(filename):
    with open(filename, 'rb') as in_file:
        return hashlib.sha1(in_file.read()).hexdigest()

CWD = os.getcwd()
PIPELINE_SHA1 = get_hash(os.path.join(CWD, 'pipeline.py'))
LUA_SHA1 = get_hash(os.path.join(CWD, 'xuite.lua'))

def stats_id_function(item):
    d = {
        'pipeline_hash': PIPELINE_SHA1,
        'lua_hash': LUA_SHA1,
        'python_version': sys.version,
    }

    return d


class ZstdDict(object):
    created = 0
    data = None

    @classmethod
    def get_dict(cls):
        if cls.data is not None and time.time() - cls.created < 1800:
            return cls.data
        response = requests.get(
            'https://legacy-api.arpa.li/dictionary',
            params={
                'project': TRACKER_ID
            }
        )
        response.raise_for_status()
        response = response.json()
        if cls.data is not None and response['id'] == cls.data['id']:
            cls.created = time.time()
            return cls.data
        print('Downloading latest dictionary.')
        response_dict = requests.get(response['url'])
        response_dict.raise_for_status()
        raw_data = response_dict.content
        if hashlib.sha256(raw_data).hexdigest() != response['sha256']:
            raise ValueError('Hash of downloaded dictionary does not match.')
        if raw_data[:4] == b'\x28\xB5\x2F\xFD':
            raw_data = zstandard.ZstdDecompressor().decompress(raw_data)
        cls.data = {
            'id': response['id'],
            'dict': raw_data
        }
        cls.created = time.time()
        return cls.data


class WgetArgs(object):
    def realize(self, item):
        wget_args = [
            WGET_AT,
            '-U', USER_AGENT,
            '-nv',
            '--host-lookups', 'dns',
            '--hosts-file', '/dev/null',
            '--resolvconf-file', '/dev/null',
            '--dns-servers', '9.9.9.10,149.112.112.10,2620:fe::10,2620:fe::fe:10',
            '--reject-reserved-subnets',
            '--content-on-error',
            '--no-http-keep-alive',
            '--no-cookies',
            '--lua-script', 'xuite.lua',
            '-o', ItemInterpolation('%(item_dir)s/wget.log'),
            '--no-check-certificate',
            '--output-document', ItemInterpolation('%(item_dir)s/wget.tmp'),
            '--truncate-output',
            '-e', 'robots=off',
            '--rotate-dns',
            '--recursive', '--level=inf',
            '--no-parent',
            '--page-requisites',
            '--timeout', '30',
            '--tries', 'inf',
            '--domains', 'xuite.net,xuite.tw,xuite.com',
            '--span-hosts',
            '--waitretry', '30',
            '--warc-file', ItemInterpolation('%(item_dir)s/%(warc_file_base)s'),
            '--warc-header', 'operator: Archive Team',
            '--warc-header', 'x-wget-at-project-version: ' + VERSION,
            '--warc-header', 'x-wget-at-project-name: ' + TRACKER_ID,
            '--warc-dedup-url-agnostic',
            '--warc-compression-use-zstd',
            '--warc-zstd-dict-no-include',
            '--header', 'Accept-Language: zh-TW,zh;q=0.9',
        ]
        dict_data = ZstdDict.get_dict()
        with open(os.path.join(item['item_dir'], 'zstdict'), 'wb') as f:
            f.write(dict_data['dict'])
        item['dict_id'] = dict_data['id']
        item['dict_project'] = TRACKER_ID
        wget_args.extend([
            '--warc-zstd-dict', ItemInterpolation('%(item_dir)s/zstdict'),
        ])

        for item_name in item['item_name'].split('\0'):
            wget_args.extend(['--warc-header', 'x-wget-at-project-item-name: '+item_name])
            wget_args.append('item-name://'+item_name)
            item_type, item_value = item_name.split(':', 1)
            # user serial number
            if item_type == 'user-sn':
                assert re.search(r'^[1-9][0-9]{7,8}$', item_value), item_value
                wget_args.extend(['--warc-header', 'xuite-user-sn: '+item_value])
                wget_args.append('https://avatar.xuite.net/'+item_value)
            # user
            elif item_type == 'user':
                assert re.search(r'^[0-9A-Za-z._]+$', item_value), item_value
                wget_args.extend(['--warc-header', 'xuite-user-id: '+item_value])
                wget_args.append('https://m.xuite.net/home/'+item_value)
            # blog
            elif item_type == 'blog':
                if item_value.count(':') == 1:
                    user_id, blog_url = item_value.split(':')
                # elif item_value.count(':') == 2:
                #     user_id, blog_url, blog_id = item_value.split(':')
                #     assert re.search(r'^[0-9]+$', blog_id), blog_id
                #     wget_args.extend(['--warc-header', 'xuite-blog-id: '+blog_id])
                else:
                    raise ValueError(item_value)
                assert re.search(r'^[0-9A-Za-z._]+$', user_id), user_id
                assert re.search(r'^[0-9A-Za-z]+$', blog_url), blog_url
                wget_args.extend(['--warc-header', 'xuite-blog-url: '+blog_url])
                wget_args.append('https://blog.xuite.net/{}/{}'.format(user_id, blog_url))
            elif item_type == 'blog-api':
                assert item_value.count(':') == 1, item_value
                user_id, blog_id = item_value.split(':')
                wget_args.append(xuite_api.api_url({
                    'method': 'xuite.blog.public.getTopArticle',
                    'blog_id': blog_id,
                    'user_id': user_id,
                }))
            # blog article
            elif item_type == 'article':
                if item_value.count(':') == 2:
                    user_id, blog_url, article_id = item_value.split(':')
                # elif item_value.count(':') == 3:
                #     user_id, blog_url, article_id, blog_id = item_value.split(':')
                #     assert re.search(r'^[0-9]+$', blog_id), blog_id
                #     wget_args.extend(['--warc-header', 'xuite-article-blog-id: '+blog_id])
                else:
                    raise ValueError(item_value)
                assert re.search(r'^[0-9A-Za-z._]+$', user_id), user_id
                assert re.search(r'^[0-9A-Za-z]+$', blog_url), blog_url
                assert re.search(r'^[0-9]+$', article_id), article_id
                wget_args.extend(['--warc-header', 'xuite-article-blog-url: '+blog_url])
                wget_args.extend(['--warc-header', 'xuite-article-id: '+article_id])
                wget_args.append('https://blog.xuite.net/{}/{}/{}'.format(user_id, blog_url, article_id))
            elif item_type == 'article-api':
                assert item_value.count(':') == 2, item_value
                user_id, blog_id, article_id = item_value.split(':')
                wget_args.append(xuite_api.api_url({
                    'method': 'xuite.blog.public.getArticle',
                    'blog_id': blog_id,
                    'user_id': user_id,
                    'article_id': article_id,
                    'blog_pw': '',
                    'article_pw': '',
                }))
            # album
            elif item_type == 'album':
                assert item_value.count(':') == 1, item_value
                user_id, album_id = item_value.split(':')
                assert re.search(r'^[0-9A-Za-z._]+$', user_id), user_id
                assert re.search(r'^[0-9]+$', album_id), album_id
                wget_args.extend(['--warc-header', 'xuite-album-id: '+album_id])
                wget_args.append('https://m.xuite.net/photo/{}/{}'.format(user_id, album_id))
            # vlog
            elif item_type == 'vlog':
                assert base64.b64decode(item_value, None, True), item_value
                decoded_FILE_NAME = base64.standard_b64decode(item_value).decode()
                media_id = re.search(r'^(?:c_)?(?:[0-9A-Za-z]{31}|[0-9A-Za-z]{6})-([0-9]+)\.(?:flv|mp4)$', decoded_FILE_NAME)
                assert media_id, decoded_FILE_NAME
                wget_args.extend(['--warc-header', 'xuite-media-id: '+media_id[1]])
                wget_args.append('https://vlog.xuite.net/play/'+item_value)
            # thumb
            elif item_type == 'pic-thumb':
                assert re.search(r'^(?:[0-9a-f]/){4}[0-9a-f]{28}/[0-9A-Za-z=]+/[1-9][0-9]*[A-Z]\.jpg$', item_value), item_value
                wget_args.extend(['--warc-header', 'xuite-pic-thumb: '+item_value])
                wget_args.append('https://pic.xuite.net/thumb/'+item_value)
            # keyword
            elif item_type == 'keyword':
                assert re.search(r'^[^?&=\x00-\x1F\x80-\xFF]+$', item_value), item_value
                wget_args.append('https://m.xuite.net/rpc/search?method=nickname&kw={}&offset=1&limit=30'.format(item_value))
            # embedded swf
            elif item_type == 'embed':
                assert re.search(r'^https?%3A%2F%2F', item_value), item_value
                item_url = urllib.parse.unquote(item_value)
                if not re.search(r'\.[Ss][Ww][Ff](?:\?[^?]+)?$', item_url):
                    raise NotImplementedError('TODO: handle <embed> other than swf')
                wget_args.append(item_url)
            # asset
            elif item_type == 'asset':
                assert re.search(r'^https?%3A%2F%2F', item_value), item_value
                item_url = urllib.parse.unquote(item_value)
                wget_args.append(item_url)
            else:
                raise ValueError('Unknown item type: '+item_type)

        item['item_name_newline'] = item['item_name'].replace('\0', '\n')

        if 'bind_address' in globals():
            wget_args.extend(['--bind-address', globals()['bind_address']])
            print('')
            print('*** Wget will bind address at {0} ***'.format(
                globals()['bind_address']))
            print('')

        return realize(wget_args, item)

###########################################################################
# Initialize the project.
#
# This will be shown in the warrior management panel. The logo should not
# be too big. The deadline is optional.
project = Project(
    title=TRACKER_ID,
    project_html='''
        <img class="project-logo" alt="Project logo" src="https://wiki.archiveteam.org/images/6/68/Xuite-icon.png" height="50px" title=""/>
        <h2>xuite.net <span class="links"><a href="https://xuite.net/">Website</a> &middot; <a href="http://tracker.archiveteam.org/#/">Leaderboard</a> &middot; <a href="https://wiki.archiveteam.org/index.php/Xuite">Wiki</a></span></h2>
        <p>Archive Xuite.</p>
    ''',
    utc_deadline = datetime.datetime(2023, 8, 31, 6, 0, 0)
)

pipeline = Pipeline(
    CheckIP(),
    GetItemFromTracker('http://{}/{}/multi={}/'
        .format(TRACKER_HOST, TRACKER_ID, MULTI_ITEM_SIZE),
        downloader, VERSION),
    PrepareDirectories(warc_prefix=TRACKER_ID),
    WgetDownload(
        WgetArgs(),
        max_tries=2,
        accept_on_exit_code=[0, 4, 8],
        env={
            'xuite_api_key': xuite_api.API_KEY,
            'xuite_secret_key': xuite_api.SECRET_KEY,
            'item_dir': ItemValue('item_dir'),
            'item_names': ItemValue('item_name_newline'),
            'warc_file_base': ItemValue('warc_file_base'),
        }
    ),
    SetBadUrls(),
    PrepareStatsForTracker(
        defaults={'downloader': downloader, 'version': VERSION},
        file_groups={
            'data': [
                ItemInterpolation('%(item_dir)s/%(warc_file_base)s.warc.zst'),
            ]
        },
        id_function=stats_id_function,
    ),
    MoveFiles(),
    LimitConcurrent(NumberConfigValue(min=1, max=20, default='20',
        name='shared:rsync_threads', title='Rsync threads',
        description='The maximum number of concurrent uploads.'),
        UploadWithTracker(
            'http://%s/%s' % (TRACKER_HOST, TRACKER_ID),
            downloader=downloader,
            version=VERSION,
            files=[
                ItemInterpolation('%(data_dir)s/%(warc_file_base)s.%(dict_project)s.%(dict_id)s.warc.zst'),
            ],
            rsync_target_source_path=ItemInterpolation('%(data_dir)s/'),
            rsync_extra_args=[
                '--recursive',
                '--partial',
                '--partial-dir', '.rsync-tmp',
                '--min-size', '1',
                '--no-compress',
                '--compress-level', '0'
            ]
        ),
    ),
    MaybeSendDoneToTracker(
        tracker_url='http://%s/%s' % (TRACKER_HOST, TRACKER_ID),
        stats=ItemValue('stats')
    )
)
