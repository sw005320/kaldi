#!/bin/bash

## 2015/11/16
## Tomohiro Tanaka
## Creating REVERB data and directory structure.
## (Real data and simulated data for dev and eval sets)

if [ -d $REVERB_home ]; then
 echo "Not creating REVERB data since it is already there."
 exit 0
fi

if [ $# -ne 2 ]; then
  echo "\nUSAGE: %s <wsjcam0 data dir> <multi-channel wsj data dir>\n"
  echo "e.g.,:"
  echo " `basename $0` /database/LDC/wsjcam0 /database/LDC/LDC2014S03"
  exit 1;
fi

if [ ! `which flac` ]; then
  echo "This processing needs \"flac\" command. Please retry after installing \"flac\" command."
  exit 1;
fi

wsjcam0=$1
multi_wsj=$2/LDC2014S03_d2
dir=`pwd`/data/local/reverb_tools

# Download tools
URL="http://reverb2014.dereverberation.com/tools/reverb_tools_for_Generate_SimData.tgz"
x=`basename $URL`
if [ ! -e $dir/$x ]; then
    wget $URL -O $dir/$x || exit 1;
    tar zxvf $dir/$x -C $dir || exit 1;
fi

# Create Simulated data
# Copy the 2 functions to ./bin/
pushd $dir/reverb_tools_for_Generate_SimData/
cp $dir/ReleasePackage/reverb_tools_for_asr_ver2.0/tools/SPHERE/nist/bin/{h_strip,w_decode} ./bin/

chmod u+x sphere_to_wave.csh
chmod u+x bin/*

tmpdir=`mktemp -d tempXXXXX `
tmpmfile=$tmpdir/run_mat.m
cat <<EOF> $tmpmfile
addpath(genpath('.'))
Generate_dtData('$wsjcam0','$reverb_dt')
Generate_etData('$wsjcam0','$reverb_et')
EOF
cat $tmpmfile | matlab -nodisplay
rm -rf $tmpdir
popd
echo "Successfully generated Simulated data."

# Create Real data
mkdir -p $reverb_real_dt/{audio/stat,etc,mlf} $reverb_real_et/{audio/stat,mlf}

# Copy data and creating directory structure
echo "Copy and create directory structure."
find $multi_wsj \( -name T? -or -name T10 \) | xargs cp -r -t $reverb_real_dt/audio/stat
find $multi_wsj \( -name T3? -or -name T40 \) | xargs cp -r -t $reverb_real_et/audio/stat
find $multi_wsj -name sentencelocation -print | xargs cp -r -t $reverb_real_dt/etc
find $multi_wsj -name WSJ.mlf | xargs cp -r -t $reverb_real_dt/mlf
find $multi_wsj -name WSJ.mlf | xargs cp -r -t $reverb_real_et/mlf

# Convert .flac file to .wav file
echo "Convert .flac file to .wav file."
echo "Log file is in $dir/flac.log"
flac -d -f --delete-input-file {$reverb_real_dt,$reverb_real_et}/audio/stat/T*/*/*.flac > flac.log 2>&1

echo "Successfully generated Real data." && exit 0;
