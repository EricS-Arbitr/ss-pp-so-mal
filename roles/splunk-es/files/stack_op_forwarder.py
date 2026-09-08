#!/usr/bin/env python3

import sys
import json
import socket
import logging
from datetime import datetime
import os
import subprocess

script_dir = os.path.dirname(os.path.abspath(__file__))
state_file = os.path.join(script_dir, 'last_notable_time.json')
output_file = os.path.join(script_dir, 'output.json')

logging.basicConfig(
    filename=os.path.join(script_dir, 'logstash_forward.log'),
    level=logging.DEBUG,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

def get_last_run_time():
    try:
        if os.path.exists(state_file):
            with open(state_file, 'r') as f:
                data = json.load(f)
                return data.get('last_time', '0')
        return '0'
    except Exception as e:
        logging.error(f"Error reading last run time: {str(e)}")
        return '0'

def save_last_run_time(timestamp):
    try:
        with open(state_file, 'w') as f:
            json.dump({'last_time': timestamp}, f)
        logging.info(f"Saved last run time: {timestamp}")
    except Exception as e:
        logging.error(f"Error saving last run time: {str(e)}")

def get_notable_data():
    try:
        last_time = get_last_run_time()
        logging.info(f"Getting notables after time: {last_time}")
        
        search_cmd = [
            '/opt/splunk/bin/splunk',
            'search',
            f'index=notable sourcetype=stash _time>{last_time} | sort _time',
            '-auth', f'admin:simspace1',
            '-output', 'json'
        ]
        
        logging.info("Executing Splunk search command")
        result = subprocess.run(search_cmd, capture_output=True, text=True)
        logging.info("Search command completed")
        
        if result.returncode == 0:
            try:
                logging.info("Parsing search results")
                
                all_events = []
                for line in result.stdout.strip().split('\n'):
                    if line.strip():
                        event = json.loads(line)
                        event.update({'SplunkES Version': '8.0.2'})
                        all_events.append(event)
                
                if not all_events:
                    logging.info("No data found in search results")
                    return None
                
                if len(all_events) > 0:
                    latest_time = all_events[-1].get('_time', '0')
                    save_last_run_time(latest_time)
                    logging.info(f"Processing {len(all_events)} events")
                
                logging.info("Successfully enriched events with SplunkES Version")
                return all_events
                
            except json.JSONDecodeError as e:
                logging.error(f"JSON decode error: {str(e)}")
                logging.error(f"Raw output: {result.stdout[:500]}")
                return None
        else:
            logging.error(f"Search failed: {result.stderr}")
            return None
            
    except Exception as e:
        logging.error(f"Error getting notable data: {str(e)}")
        raise

def write_to_file(events):
    try:
        logging.info(f"Writing data to {output_file}")
        with open(output_file, 'w') as f:
            f.write(json.dumps(events, indent=2))
        logging.info("Successfully wrote data to file")
    except Exception as e:
        logging.error(f"Error writing to file: {str(e)}")
        sys.exit(2)

def send_to_logstash(events):
    LOGSTASH_HOST = "10.255.240.1"
    LOGSTASH_PORT = 601

    try:
        logging.info(f"Attempting to connect to Logstash at {LOGSTASH_HOST}:{LOGSTASH_PORT}")
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect((LOGSTASH_HOST, LOGSTASH_PORT))
        logging.info("Successfully connected to Logstash")

        for event in events:
            try:
                event_data = json.dumps(event) + '\n'
                sock.sendall(event_data.encode())
                logging.info(f"Sent event with time {event.get('_time')} to Logstash")
            except Exception as e:
                logging.error(f"Error sending event to Logstash: {str(e)}")
                continue
                
        logging.info(f"Finished sending {len(events)} events to Logstash")
        
    except Exception as e:
        logging.error(f"Error connecting to Logstash: {str(e)}")
    finally:
        try:
            sock.close()
            logging.info("Closed Logstash connection")
        except:
            pass

if __name__ == "__main__":
    try:
        logging.info("Script started")
        notable_events = get_notable_data()
        if notable_events:
            write_to_file(notable_events)
            send_to_logstash(notable_events)
            logging.info("Script completed successfully")
        else:
            logging.info("No notable data to process")
    except Exception as e:
        logging.error(f"Error in main: {str(e)}")
        sys.exit(2)