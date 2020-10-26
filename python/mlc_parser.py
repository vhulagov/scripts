# -*- coding: utf-8 -*-

from __future__ import print_function

import os
from time import time
import argparse

from socket import socket, AF_INET6, SOCK_STREAM
import json

import midecode
import subprocess

logging.basicConfig(
    level=logging.DEBUG,
    format='[%(asctime)s] {%(filename)s:%(lineno)d} %(levelname)s - %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger()

MAC = os.environ['MAC']

# Legacy Graphite component
CARBON_SERVER = os.environ['SERVER']
CARBON_PORT = 42000
CARBON_ROOT_PATH = 'rnd.validation.ram.testresults'

# Testing applications
MLC_CMD = 'mlc_avx512'
SAT_CMD = 'stressapptest'

IDLE_LATENCIES = 'Measuring idle latencies'
PEAK_BANDWIDTH = 'Measuring Peak Memory Bandwidths'
BANDWIDTH_BETWEEN_NODES = 'Measuring Memory Bandwidths between nodes'
LOADED_LATENCIES = 'Measuring Loaded Latencies'


def get_dimm_part_number():
    dmi = warden.utils.dmidecode.dmidecode()
    for dimm in dmi['Memory']:
        if dimm['part number'] and dimm['part number'] != 'Not Specified' :
            return dimm['part number'].replace('.','_')

def get_inventory_number(server, mac):
    import httplib
    conn = httplib.HTTPConnection(server)
    conn.request("GET","/computer/list.cli?f="+str(mac))
    response = conn.getresponse()
    for line in response.read().splitlines():
        eine_comp = line.split()
        if eine_comp[0].isdigit() and len(str(eine_comp[0])) == 9:
            inventory = eine_comp[0]
    conn.close()
    return inventory

INVENTORY = get_inventory_number(CARBON_SERVER,MAC)
DIMM_PN = get_dimm_part_number()

def send_graphite_metric(metric, timestamp=None):
    timestamp = int(time())
    message = "%s.%s.%s.%s %s\n" % (CARBON_ROOT_PATH, INVENTORY, DIMM_PN, metric, timestamp)

    sock = socket(AF_INET6, SOCK_STREAM)
    sock.connect((CARBON_SERVER, CARBON_PORT))
    from dmp_suite.string_utils import to_bytes
    sock.sendall(to_bytes(message))
    sock.close()

def process_idle_latencies(res_block, idle_latencies, idle_latencies_fullset):
    for line in res_block.splitlines():
        splited_line = line.split()
        if not splited_line or not splited_line[0].isdigit():
            continue
        node_id = int(splited_line[0])
        target_latencies = {}
        for index, element in enumerate(splited_line[1:], 0):
            target_latencies[index] = float(element)
        #idle_latencies[node_id] = target_latencies
        idle_latencies.append(target_latencies)
        idle_latencies_fullset.extend(idle_latencies[node_id].values())

def process_peak_bandwidth(res_block, peak_bandwidth):
    for line in res_block.splitlines():
        if ':  ' in line:
            key, value = line.split(':  ', 1)
            key = key.lower().replace(' ','-').replace(':','-').rstrip('-')
            value = float(value.strip())
            peak_bandwidth[key] = value

def process_bandwidth_between_nodes(res_block, bandwidth_bw_nodes, bandwidth_bw_nodes_fullset):
    for line in res_block.splitlines():
        splited_line = line.split()
        if not splited_line or not splited_line[0].isdigit():
            continue
        node_id = int(splited_line[0])
        target_bandwidth = {}
        for index, element in enumerate(splited_line[1:], 0):
            target_bandwidth[index] = float(element)
        bandwidth_bw_nodes.append(target_bandwidth)
        bandwidth_bw_nodes_fullset.extend(list(bandwidth_bw_nodes[node_id].values()))

def process_load_latencies(res_block, loaded_latencies, loaded_delay_fullset, loaded_bandwidth_fullset):
    for line in res_block.splitlines():
        splited_line = line.split()
        if not splited_line or not splited_line[0].isdigit():
            continue
        node_id = int(splited_line[0])
        target_latencies = {}
        for index, element in enumerate(splited_line, 0):
            target_latencies[index] = float(element)
        loaded_latencies.append(target_latencies)
        loaded_delay_fullset.append(target_latencies[1])
        loaded_bandwidth_fullset.append(target_latencies[2])

def mlc():
    """
    Run Intel MLC test, parse and return the output
    """
    idle_latencies = []
    idle_latencies_fullset = []
    peak_bandwidth = {}
    bandwidth_bw_nodes = []
    bandwidth_bw_nodes_fullset = []
    loaded_latencies = []
    loaded_delay_fullset = []
    loaded_latencies_fullset = []
    loaded_bandwidth_fullset = []

    #cmd = 'cat /home/lacitis/WORK/UTILS/INTEL/MLC/output.example'
    try:
        result = subprocess.run(
            MLC_CMD,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            encoding='utf-8',
            errors='replace',
            timeout=duration + 30
        )
    except subprocess.TimeoutExpired:
				logger.error('MLC is not responding')
        return False

    if result.returncode != 0:
				logger.error('MLC exit with non zer exit code: ' + result.returncode )
        return False

    for res_block in result.stdout.split('\n\n'):
        logger.debug(res_block)
        if IDLE_LATENCIES in res_block:
            process_idle_latencies(res_block, idle_latencies, idle_latencies_fullset)
            logger.debug(json.dumps(idle_latencies, indent=2))
        elif PEAK_BANDWIDTH in res_block:
            process_peak_bandwidth(res_block, peak_bandwidth)
            logger.debug(json.dumps(peak_bandwidth), indent=2))
        if BANDWIDTH_BETWEEN_NODES in res_block:
            process_bandwidth_between_nodes(res_block, bandwidth_bw_nodes, bandwidth_bw_nodes_fullset)
            logger.debug(json.dumps(bandwidth_bw_nodes), indent=2))
        if LOADED_LATENCIES in res_block:
            process_load_latencies(res_block, loaded_latencies, loaded_delay_fullset, loaded_bandwidth_fullset)
            logger.debug(json.dumps(loaded_latencies, indent=2))
            logger.debug(json.dumps(loaded_bandwidth_fullset, indent=2))

    return job['return_code'], idle_latencies, bandwidth_bw_nodes, loaded_latencies, loaded_bandwidth_fullset

def main():
    """
    The main function
    """
    args = argument_parsing()
    benchmark.common.verbose = args.verbose
    TestResult.task_id = args.task_id
    conf = Conf(OPTIONS, args.config, log=False)
    test_name = 'performance'
    result = TestResult(conf, test_name)
    analyze_rmt(result, args)
    result.finish()
    model = 'Unknown'
    if result.component and not args.disable_sending:
        model = result.component[0].get('model')
        result.send_component_info(conf['report']['api_url'], result.component, args.startrek)
    tags = [model]
    if args.tags:
        tags.extend(tag.strip() for tag in args.tags.split(','))
    TestResult.add_tags(tags)
    #log_msg(json.dumps(result.get_result_dict(), indent=2), force=True)
    filename = '{0}_{1}_{2}.json'.format(model, test_name, result.started_at)
    result.save_to_file(filename)
    if not args.disable_sending:
        result.send_via_api(conf['report']['api_url'])


if __name__ == '__main__':
    main()
