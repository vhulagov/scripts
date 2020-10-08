# -*- coding: utf-8 -*-

import os
from os import environ
import sys
import argparse
import logging

from collections import defaultdict
import json

from socket import socket, AF_INET6, SOCK_STREAM

logging.basicConfig(
    level=logging.DEBUG,
    format='[%(asctime)s] {%(filename)s:%(lineno)d} %(levelname)s - %(message)s',
    stream=sys.stdout
)

logger = logging.getLogger()

MAC = os.environ['MAC']
DATA_SERVER = os.environ['SERVER']

def get_inventory_number(mac):
    from requests import Session
    inventory = ''
    data_api = 'https://data.ru/api/v2/computers/hostname/{}'.format(host)
    try:
        req = Session.get( data_api, params={'fields': 'inventory'}, timeout=10, )
        inv_raw = res.json()['result']
        if inv_raw.isdigit() and len(str(inv_raw)) == 9:
            inventory = inv_raw
        return inventory
    except (IOError, KeyError, TypeError) as exc:
        raise ApiError from exc

def get_dimm_pn():
    import subprocess
    import re
    proc = subprocess.Popen(['dmidecode %s %s' %('-t', '17')], shell = True, stderr=subprocess.STDOUT, stdout=subprocess.PIPE)
    stdout, stderr = proc.communicate()
    if proc.returncode > 0:
        raise RuntimeError("{} failed with an error:\n{}".format(self.dmidecode, stdout.decode()))
    else:
        dimm_pns = set(re.findall(r'Part Number: (.*)', stdout.decode()))
        dimm_pns -= {'NO DIMM'}
        if len(dimm_pns) == 2:
            return dimm_pns.pop().strip()
        else:
            return False
          

INVENTORY = get_inventory_number(environ['MAC'])
DIMM_PN = get_dimm_pn()

CARBON_SERVER = 'raphite-dev.data.ru'
CARBON_PORT = 2024
CARBON_ROOT_PATH = 'rnd.validation.ram.amd_mbist'

class AmdMemDataEye:
    def tree(self):
        return defaultdict(self.tree)

    def __init__(self, efivar):
        self.AmdMemDataEye_def_path = '/sys/firmware/efi/efivars/AmdMemDataEye-645ae32e-c5e5-48aa-bc18-24e0676e7641'
        self.mbist_test_status_offset = 0xa4
        self.margin_params = [ 'RxDqs-', 'RxDqs+', 'RxV-', 'RxV+', 'TxDq-', 'TxDq+', 'TxV-', 'TxV+' ]
        self.mbist_data = self.tree()
        self.mbist_worst_case_result = {}
        self.efivar_handle = efivar
        print(efivar)

        with open(self.efivar_handle, 'rb') as f:
            platform_info_hex = f.read(4)
            # sockets_cnt = 2
            sockets_cnt = platform_info_hex[0]
            print(int(sockets_cnt))
            #dies_per_socket = 1
            dies_per_socket = platform_info_hex[1]
            #channels_per_socket = 8
            channels_per_socket = platform_info_hex[3]
            #subtest_cnt = 5
            subtest_cnt =  platform_info_hex[2]
            f.seek(self.mbist_test_status_offset)
            #dataeye = list(f.read(mbist_test_status_offset))
            for s in range(0, sockets_cnt):
                #print("SOCKET:" + str(s))
                for die in range(0, dies_per_socket):
                    #print("  DIE:" + str(die))
                    for ch in range(0, channels_per_socket):
                        for cs in range(0, 4):
                            dataeye_margin = list(f.read(9))
                            if dataeye_margin[0]:
                                #print(dataeye_margin[1:])
                                #self.mbist_data[s][die][ch][cs] = dataeye_margin[1:]
                                self.mbist_data['{}.{}.{}.{}'.format(s,die,ch,cs)] = dataeye_margin[1:]
                                #print('{}.{}.{}.{}  '.format(s,die,ch,cs) + ' '.join(str(i) for i in dataeye_margin[1:]))

    def get_worst_case(self):
        #self.margin_params = ['RxDqs-', 'RxDqs+', 'RxV-', 'RxV+', 'TxDq-', 'TxDq+', 'TxV-', 'TxV+', 'Cmd-', 'Cmd+', 'CmdV-', 'CmdV+', 'Ctl-', 'Ctl+']
        worst_margin_dimm = self.tree()
        worst_margin = {}
        mparam_value = {}
        if self.mbist_data:
            for mparam in self.margin_params:
                self.mbist_worst_case_result[mparam] = {}
                logger.debug("PARAM: " + mparam)
                logger.debug(self.mbist_data.items())
                for dimm, margins in self.mbist_data.items():
                    dimm_margins = dict(zip(self.margin_params, margins))
#                    print(dimm_margins)
#                    print(dimm_margins.values())
#                    print(dimm_margins[mparam])
                    worst_margin_dimm[dimm] = min(dimm_margins.values(), key=lambda x: abs(x[mparam]))
                    #worst_margin_dimm[dimm] = min(dimm_margins.values(), key=lambda x: abs(x[mparam]))
#                self.mbist_worst_case_result[mparam] = min(worst_margin_dimm.values(), key=lambda x: abs(x[mparam]))[mparam]
                mbist_worst_case_result_min = min(worst_margin_dimm.values(), key=lambda x: abs(x[mparam]))[mparam]
                self.mbist_worst_case_result[mparam][mbist_worst_case_result_min] = list()
                for dimm, params in worst_margin_dimm.items():
                    try:
                        worst_dimm = params.values().index(mbist_worst_case_result_min)
                        self.mbist_worst_case_result[mparam][mbist_worst_case_result_min].append(dimm)
                    except ValueError:
                        continue

    def send_metrics_graphite(self):
        timestamp = int(time())
        for res in self.mbist_data:
            message += "%s.%s.%s.%s %s\n" % (CARBON_ROOT_PATH, INVENTORY, res.key(), res.value(), timestamp)

        sock = socket(AF_INET6, SOCK_STREAM)
        sock.connect((CARBON_SERVER, CARBON_PORT))
        sock.sendall(message)
        sock.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('efi_var_dump')
    args = parser.parse_args()

    if args.efi_var_dump:
        amd_memeye = AmdMemDataEye(args.efi_var_dump)
    else:
        amd_memeye = AmdMemDataEye()

    amd_memeye.send_metrics_graphite()
    #amd_memeye.get_worst_case()
    #print(json.dumps(amd_memeye.mbist_data, indent=2))

# vim: set expandtab: tabstop=4:
