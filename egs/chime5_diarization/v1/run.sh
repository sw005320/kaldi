#!/bin/bash
# Copyright   2017   Johns Hopkins University (Author: Daniel Garcia-Romero)
#             2017   Johns Hopkins University (Author: Daniel Povey)
#        2017-2018   David Snyder
#             2018   Ewald Enzinger
#             2018   Zili Huang
#             2018   Shinji Watanabe
# Apache 2.0.
#
# See ../README.txt for more info on data required.
# Results (diarization error rate) are inline in comments below.

# Begin configuration section.
stage=0
enhancement=beamformit # enhancement method
# End configuration section
. ./utils/parse_options.sh

. ./cmd.sh
. ./path.sh

set -e # exit on error

mfccdir=`pwd`/mfcc
vaddir=`pwd`/mfcc

# diarization related
voxceleb1_root=/export/corpora/VoxCeleb1
voxceleb2_root=/export/corpora/VoxCeleb2
num_components=2048
ivector_dim=400
ivec_dir=exp/extractor_c${num_components}_i${ivector_dim}

# chime5 main directory path
# please change the path accordingly
chime5_corpus=/export/corpora4/CHiME5
json_dir=${chime5_corpus}/transcriptions
audio_dir=${chime5_corpus}/audio
# preliminary investigation shows that array u06 scores the best DER performance
# exp/extractor_c2048_i400/results_u01/DER_threshold.txt:61.00
# exp/extractor_c2048_i400/results_u02/DER_threshold.txt:62.86
# exp/extractor_c2048_i400/results_u03/DER_threshold.txt:60.88
# exp/extractor_c2048_i400/results_u04/DER_threshold.txt:64.44
# exp/extractor_c2048_i400/results_u06/DER_threshold.txt:59.77
# skip u05 as it is missing
mictype=u06

if [ $stage -le 0 ]; then
  local/make_voxceleb2.pl $voxceleb2_root dev data/voxceleb2_train
  local/make_voxceleb2.pl $voxceleb2_root test data/voxceleb2_test
  # This script creates data/voxceleb1_test and data/voxceleb1_train.
  # Our evaluation set is the test portion of VoxCeleb1.
  local/make_voxceleb1.pl $voxceleb1_root data
  # We'll train on all of VoxCeleb2, plus the training portion of VoxCeleb1.
  # This should give 7,351 speakers and 1,277,503 utterances.
  utils/combine_data.sh data/train data/voxceleb2_train data/voxceleb2_test data/voxceleb1_train

  # Prepare the development and evaluation set for CHiME-5.
  local/prepare_data.sh --mictype ${mictype} \
			${audio_dir}/train ${json_dir}/train data/train_${mictype}
fi

if [ $stage -le 1 ]; then
  for dset in dev eval; do
    name=${dset}_${mictype}
    # use the original CHiME-5 data preparation script
    # note that this includes speaker ID information, which must not be used in diarization
    local/prepare_data.sh --mictype ${mictype} \
			  ${audio_dir}/${dset} ${json_dir}/${dset} data/${name}
    # preparing rttm
    steps/segmentation/convert_utt2spk_and_segments_to_rttm.py \
      data/${name}/utt2spk \
      data/${name}/segments \
      data/${name}/rttm
    # remove speaker ID information for text
    mv data/${name}/text data/${name}/text.org
    paste -d " " \
      <(awk '{print $1}' data/${name}/text.org | sed -e "s/.*\(S.*_U.*\)_.*\(\.CH..*\)/\1\2/") \
      <(cut -f 2- -d" " data/${name}/text.org) \
      > data/${name}/text_tmp
    sort -k1,1 data/${name}/text_tmp > data/${name}/text
    rm data/${name}/text_tmp
    rm data/${name}/text.org
    # preparing utt2spk, spk2utt, segments
    python local/prepare_utt2spk_segments.py data/${name}
    utils/utt2spk_to_spk2utt.pl data/${name}/utt2spk > data/${name}/spk2utt
    ## preparing reco2num_spk
    ## CHiME-5 always has "4" speakers per recording
    awk '{print $2 " 4"}' data/${name}/rttm \
      | sort | uniq > data/${name}/reco2num_spk
    # sort the rttm file
    sort -k2,2 -k4,4n data/${name}/rttm > data/${name}/rttm_tmp
    mv data/${name}/rttm_tmp data/${name}/rttm 
    rm data/${name}/text
    utils/fix_data_dir.sh data/${name}
  done
fi

if [ $stage -le 2 ]; then
  # Make MFCCs for each dataset
  for name in train; do
    steps/make_mfcc.sh --write-utt2num-frames true \
		       --mfcc-config conf/mfcc.conf --nj 40 --cmd "$train_cmd --max-jobs-run 20" \
		       data/${name} exp/make_mfcc_${name} $mfccdir
    utils/fix_data_dir.sh data/${name}
  done
  for name in dev_${mictype} eval_${mictype}; do
    steps/make_mfcc.sh --write-utt2num-frames true \
		       --mfcc-config conf/mfcc.conf --nj 8 --cmd "$train_cmd" \
		       data/${name} exp/make_mfcc_${name} $mfccdir
    utils/fix_data_dir.sh data/${name}
  done
  
  # Compute the energy-based VAD for train
  sid/compute_vad_decision.sh --nj 20 --cmd "$train_cmd" \
    data/train exp/make_vad $vaddir
  utils/fix_data_dir.sh data/train
  
  # This writes features to disk after adding deltas and applying the sliding window CMN.
  # Although this is somewhat wasteful in terms of disk space, for diarization
  # it ends up being preferable to performing the CMN in memory.  If the CMN
  # were performed in memory it would need to be performed after the subsegmentation,
  # which leads to poorer results.
  ###for name in train dev_${enhancement}_ref eval_${enhancement}_ref; do
  for name in train; do
    local/prepare_feats.sh --nj 40 --cmd "$train_cmd" \
			   data/$name data/${name}_cmn exp/${name}_cmn
    if [ -f data/$name/vad.scp ]; then
      cp data/$name/vad.scp data/${name}_cmn/
    fi
    if [ -f data/$name/segments ]; then
      cp data/$name/segments data/${name}_cmn/
    fi
    utils/fix_data_dir.sh data/${name}_cmn
  done
  for name in dev_${mictype} eval_${mictype}; do
    local/prepare_feats.sh --nj 8 --cmd "$train_cmd" \
			   data/$name data/${name}_cmn exp/${name}_cmn
    if [ -f data/$name/vad.scp ]; then
      cp data/$name/vad.scp data/${name}_cmn/
    fi
    if [ -f data/$name/segments ]; then
      cp data/$name/segments data/${name}_cmn/
    fi
    utils/fix_data_dir.sh data/${name}_cmn
  done
  
  echo "0.01" > data/train_cmn/frame_shift
  # Create segments to extract i-vectors from for PLDA training data.
  # The segments are created using an energy-based speech activity
  # detection (SAD) system, but this is not necessary.  You can replace
  # this with segments computed from your favorite SAD.
  diarization/vad_to_segments.sh --nj 20 --cmd "$train_cmd" \
      data/train_cmn data/train_cmn_segmented
fi

if [ $stage -le 3 ]; then
  # Train the UBM on VoxCeleb 1 and 2.
  sid/train_diag_ubm.sh --cmd "$train_cmd --mem 4G" \
    --nj 40 --num-threads 8 \
    data/train $num_components \
    exp/diag_ubm

  sid/train_full_ubm.sh --cmd "$train_cmd --mem 25G" \
    --nj 40 --remove-low-count-gaussians false \
    data/train \
    exp/diag_ubm exp/full_ubm
fi

if [ $stage -le 4 ]; then
  # In this stage, we train the i-vector extractor on a subset of VoxCeleb 1
  # and 2.
  #
  # Note that there are well over 1 million utterances in our training set,
  # and it takes an extremely long time to train the extractor on all of this.
  # Also, most of those utterances are very short.  Short utterances are
  # harmful for training the i-vector extractor.  Therefore, to reduce the
  # training time and improve performance, we will only train on the 100k
  # longest utterances.
  utils/subset_data_dir.sh \
    --utt-list <(sort -n -k 2 data/train/utt2num_frames | tail -n 100000) \
    data/train data/train_100k

  # Train the i-vector extractor.
  sid/train_ivector_extractor.sh --cmd "$train_cmd --mem 16G" \
    --ivector-dim $ivector_dim --num-iters 5 \
    exp/full_ubm/final.ubm data/train_100k \
    $ivec_dir
fi

if [ $stage -le 5 ]; then
  # Extract i-vectors for CHiME-5 development and evaluation set. 
  # We set apply-cmn false and apply-deltas false because we already add
  # deltas and apply cmn in stage 1.
  diarization/extract_ivectors.sh --cmd "$train_cmd --mem 20G" \
				  --nj 8 --window 1.5 --period 0.75 --apply-cmn false --apply-deltas false \
				  --min-segment 0.5 $ivec_dir \
				  data/dev_${mictype}_cmn $ivec_dir/ivectors_dev_${mictype}
  diarization/extract_ivectors.sh --cmd "$train_cmd --mem 20G" \
				  --nj 8 --window 1.5 --period 0.75 --apply-cmn false --apply-deltas false \
				  --min-segment 0.5 $ivec_dir \
				  data/eval_${mictype}_cmn $ivec_dir/ivectors_eval_${mictype}

  # Reduce the amount of training data for the PLDA training.
  utils/subset_data_dir.sh data/train_cmn_segmented 128000 data/train_cmn_segmented_128k
  # Extract i-vectors for the VoxCeleb, which is our PLDA training
  # data.  A long period is used here so that we don't compute too
  # many i-vectors for each recording.
  diarization/extract_ivectors.sh --cmd "$train_cmd --mem 25G" \
    --nj 20 --window 3.0 --period 10.0 --min-segment 1.5 --apply-cmn false --apply-deltas false \
    --hard-min true $ivec_dir \
    data/train_cmn_segmented_128k $ivec_dir/ivectors_train_segmented_128k
fi

if [ $stage -le 6 ]; then
  # Train a PLDA model on VoxCeleb, using CHiME-5 development set to whiten.
  "$train_cmd" $ivec_dir/ivectors_dev_${mictype}/log/plda.log \
    ivector-compute-plda ark:$ivec_dir/ivectors_train_segmented_128k/spk2utt \
      "ark:ivector-subtract-global-mean \
      scp:$ivec_dir/ivectors_train_segmented_128k/ivector.scp ark:- \
      | transform-vec $ivec_dir/ivectors_dev_${mictype}/transform.mat ark:- ark:- \
      | ivector-normalize-length ark:- ark:- |" \
      $ivec_dir/ivectors_dev_${mictype}/plda || exit 1;
fi

# Perform PLDA scoring
if [ $stage -le 7 ]; then
  # Perform PLDA scoring on all pairs of segments for each recording.
  diarization/score_plda.sh --cmd "$train_cmd --mem 4G" \
    --nj 8 $ivec_dir/ivectors_dev_${mictype} $ivec_dir/ivectors_dev_${mictype} \
    $ivec_dir/ivectors_dev_${mictype}/plda_scores

  diarization/score_plda.sh --cmd "$train_cmd --mem 4G" \
    --nj 8 $ivec_dir/ivectors_dev_${mictype} $ivec_dir/ivectors_eval_${mictype} \
    $ivec_dir/ivectors_eval_${mictype}/plda_scores
fi

# Cluster the PLDA scores using a stopping threshold.
if [ $stage -le 8 ]; then
  # First, we find the threshold that minimizes the DER on CHiME-5 development set.
  mkdir -p $ivec_dir/tuning
  echo "Tuning clustering threshold for CHiME-5 development set"
  best_der=100
  best_threshold=0

  # The threshold is in terms of the log likelihood ratio provided by the
  # PLDA scores.  In a perfectly calibrated system, the threshold is 0.
  # In the following loop, we evaluate DER performance on CHiME-5 development 
  # set using some reasonable thresholds for a well-calibrated system.
  for threshold in -0.5 -0.4 -0.3 -0.2 -0.1 -0.05 0 0.05 0.1 0.2 0.3 0.4 0.5; do
    diarization/cluster.sh --cmd "$train_cmd --mem 20G" --nj 8 \
      --threshold $threshold --rttm-channel 1 $ivec_dir/ivectors_dev_${mictype}/plda_scores \
      $ivec_dir/ivectors_dev_${mictype}/plda_scores_t$threshold

    # for some reason the duration becomes the negative, which will be removed
    mv $ivec_dir/ivectors_dev_${mictype}/plda_scores_t$threshold/rttm $ivec_dir/ivectors_dev_${mictype}/plda_scores_t$threshold/rttm.bak
    grep -v "\-[0-9]" $ivec_dir/ivectors_dev_${mictype}/plda_scores_t$threshold/rttm.bak > $ivec_dir/ivectors_dev_${mictype}/plda_scores_t$threshold/rttm
    
    md-eval.pl -r data/dev_${mictype}/rttm \
     -s $ivec_dir/ivectors_dev_${mictype}/plda_scores_t$threshold/rttm \
     2> $ivec_dir/tuning/dev_${mictype}_t${threshold}.log \
     > $ivec_dir/tuning/dev_${mictype}_t${threshold}

    der=$(grep -oP 'DIARIZATION\ ERROR\ =\ \K[0-9]+([.][0-9]+)?' \
      $ivec_dir/tuning/dev_${mictype}_t${threshold})
    if [ $(echo $der'<'$best_der | bc -l) -eq 1 ]; then
      best_der=$der
      best_threshold=$threshold
    fi
  done
  echo "$best_threshold" > $ivec_dir/tuning/dev_${mictype}_best

  diarization/cluster.sh --cmd "$train_cmd --mem 20G" --nj 8 \
    --threshold $(cat $ivec_dir/tuning/dev_${mictype}_best) --rttm-channel 1 \
    $ivec_dir/ivectors_dev_${mictype}/plda_scores $ivec_dir/ivectors_dev_${mictype}/plda_scores

  # Cluster CHiME-5 evaluation set using the best threshold found for the CHiME-5
  # development set. The CHiME-5 development set is used as the validation 
  # set to tune the parameters. 
  diarization/cluster.sh --cmd "$train_cmd --mem 20G" --nj 8 \
    --threshold $(cat $ivec_dir/tuning/dev_${mictype}_best) --rttm-channel 1 \
    $ivec_dir/ivectors_eval_${mictype}/plda_scores $ivec_dir/ivectors_eval_${mictype}/plda_scores

  # for some reason the duration becomes the negative, which will be removed
  mv $ivec_dir/ivectors_eval_${mictype}/plda_scores/rttm $ivec_dir/ivectors_eval_${mictype}/plda_scores/rttm.bak
  grep -v "\-[0-9]" $ivec_dir/ivectors_eval_${mictype}/plda_scores/rttm.bak > $ivec_dir/ivectors_eval_${mictype}/plda_scores/rttm
  
  mkdir -p $ivec_dir/results_${mictype}
  # Compute the DER on the CHiME-5 evaluation set. We use the official metrics of   
  # the DIHARD challenge. The DER is calculated with no unscored collars and including  
  # overlapping speech.
  md-eval.pl -r data/eval_${mictype}/rttm \
    -s $ivec_dir/ivectors_eval_${mictype}/plda_scores/rttm 2> $ivec_dir/results_${mictype}/threshold.log \
    > $ivec_dir/results_${mictype}/DER_threshold.txt
  der=$(grep -oP 'DIARIZATION\ ERROR\ =\ \K[0-9]+([.][0-9]+)?' \
    $ivec_dir/results_${mictype}/DER_threshold.txt)
  # Using supervised calibration, DER: 28.51%
  echo "Using supervised calibration, DER: $der%"
fi

# Cluster the PLDA scores using the oracle number of speakers
if [ $stage -le 9 ]; then
  # In this section, we show how to do the clustering if the number of speakers
  # (and therefore, the number of clusters) per recording is known in advance.
  diarization/cluster.sh --cmd "$train_cmd --mem 20G" --nj 8 \
    --reco2num-spk data/eval_${mictype}/reco2num_spk --rttm-channel 1 \
    $ivec_dir/ivectors_eval_${mictype}/plda_scores $ivec_dir/ivectors_eval_${mictype}/plda_scores_num_spk

  # for some reason the duration becomes the negative, which will be removed
  mv $ivec_dir/ivectors_eval_${mictype}/plda_scores_num_spk/rttm $ivec_dir/ivectors_eval_${mictype}/plda_scores_num_spk/rttm.bak
  grep -v "\-[0-9]" $ivec_dir/ivectors_eval_${mictype}/plda_scores_num_spk/rttm.bak > $ivec_dir/ivectors_eval_${mictype}/plda_scores_num_spk/rttm

  md-eval.pl -r data/eval_${mictype}/rttm \
    -s $ivec_dir/ivectors_eval_${mictype}/plda_scores_num_spk/rttm 2> $ivec_dir/results_${mictype}/num_spk.log \
    > $ivec_dir/results_${mictype}/DER_num_spk.txt
  der=$(grep -oP 'DIARIZATION\ ERROR\ =\ \K[0-9]+([.][0-9]+)?' \
    $ivec_dir/results_${mictype}/DER_num_spk.txt)
  # Using the oracle number of speakers, DER: 24.42%
  echo "Using the oracle number of speakers, DER: $der%"
fi
