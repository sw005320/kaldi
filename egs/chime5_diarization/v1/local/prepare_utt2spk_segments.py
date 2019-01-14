#!/usr/bin/env python3

# This script prepares data for CHiME-5. It creates utt2spk and segments 
# for CHiME-5 diarization.

import sys

def prepare_chime5_data(data_dir):
    with open("{}/text".format(data_dir), 'r') as fh:
        content = fh.readlines()

    # merge the overlap segments 
    segment_dict = {}
    last_uttname = ''
    for line in content:
        line = line.strip('\n')
        subuttname = line.split()[0]
        uttname = subuttname.split('-')[0]
        if uttname != last_uttname: # new utterance
            if last_uttname != '':
                segment_dict[last_uttname].append([last_start_time, last_end_time]) 
            segment_dict[uttname] = []
            last_end_time = -1
            last_uttname = uttname
        start_time = int(subuttname.split('-')[-2]) / 100.0
        end_time = int(subuttname.split('-')[-1]) / 100.0
        assert start_time < end_time
        if start_time > last_end_time: # there is no overlap
            if last_end_time != -1:
                segment_dict[uttname].append([last_start_time, last_end_time])
            last_start_time = start_time
            last_end_time = end_time
        else: # there is overlap
            last_end_time = max(last_end_time, end_time)
    segment_dict[last_uttname].append([last_start_time, last_end_time])
    utt_list = list(segment_dict.keys())

    # create utt2spk and segments file
    utt2spk_file = open("{}/utt2spk".format(data_dir), 'w')
    segments_file = open("{}/segments".format(data_dir), 'w')
    for utt in utt_list:
        segment_list = segment_dict[utt]
        for segment in segment_list:
            segment_name = "{}-{}-{}".format(utt, str(int(segment[0] * 100)).zfill(7), str(int(segment[1] * 100)).zfill(7))
            segments_file.write("{} {} {:.2f} {:.2f}\n".format(segment_name, utt, segment[0], segment[1]))
            utt2spk_file.write("{} {}\n".format(segment_name, utt))
    utt2spk_file.close()
    segments_file.close()
    return 0

def main():
    data_dir = sys.argv[1]
    prepare_chime5_data(data_dir)
    return 0

if __name__ == "__main__":
    main()
