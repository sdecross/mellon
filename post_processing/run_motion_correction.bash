#!/bin/bash
#
#Ensure that the appropriate python libraries are available
#e.g., `source activate my_conda_env`

OVERWRITE_REGRESS=0

#set to ensure 3dDespike uses only 1 thread
export OMP_NUM_THREADS=1

version=$(python -V 2>&1 | grep -Po '(?<=Python )(.+)')
if [[ -z "$version" ]]
then
    echo "No Python!" 
    exit
fi
parsedVersion=$(echo "${version//./}")
if [[ "$parsedVersion" -gt "299" ]]
then 
    echo "Valid Python version: $version"
else
    echo "Invalid Python version: $version"
    echo "Did you run 'scl enable rh-python36 bash'?"
    exit
fi

module load afni

#location of motion regression script
regress_script="/home/jflournoy/code/mellon/post_processing/regress.py"

#set some paths
bids_derivs="/data/mounts/scs-fs-20/kpsy/genr/mrdata/GenR_MRI/bids/derivatives/fmriprep"
outdir="/data/mounts/scs-fs-20/kpsy/genr/users/jflournoy/GenR_motion"

#set to either T1w, or MNI152NLin2009cAsym
#space="MNI152NLin2009cAsym"
space="T1w"
strategy="36P"

mask_postfix="brain_mask.nii.gz"
bold_postfix="preproc_bold.nii.gz"
despike_postfix="despike_bold.nii.gz"
confounds_postfix="confounds_regressors.tsv"

#subject_list="/home/jflournoy/code/mellon/post_processing/subject_list.txt"
subject_list=$1
echo "using subject list $subject_list"

#for isRunning
postfix="motcorr"
isRunning="/home/jflournoy/code/mellon/post_processing/isRunning_motion_correction"

#get a list of subject data
subjects=(`cat $subject_list`)


#run a loop
for subj in ${subjects[*]} ; do
	echo "Checking $subj"

	subj_rs_bold=$( ls ${bids_derivs}/${subj}/ses-F09/func/${subj}_ses-F09_task-rest_acq-*_run-*_space-${space}_desc-${bold_postfix} )
	subj_mask=$( ls ${bids_derivs}/${subj}/ses-F09/func/${subj}_ses-F09_task-rest_acq-*_run-*_space-${space}_desc-${mask_postfix} )
	subj_confounds=$( ls ${bids_derivs}/${subj}/ses-F09/func/${subj}_ses-F09_task-rest_acq-*_run-*_desc-${confounds_postfix} )
	rs_filename=$( basename ${subj_rs_bold} )
	filename_stem=${rs_filename%${bold_postfix}}

	subj_outdir=${outdir}/${subj}/ses-F09/func
	subj_dspk_out=${subj_outdir}/${filename_stem}${despike_postfix}
	subj_mtcr_out=${subj_outdir}/${filename_stem}${strategy}_
	subj_mtcr_check=${subj_mtcr_out}nuisanced_bold.nii.gz

        #check if the 'target' processing is done
        if [ -e ${subj_mtcr_check} ] && [ ! $OVERWRITE_REGRESS -eq 1 ] ; then
		#if it is there, skip
                echo "Skipping ${subj}: output exists" 
                continue
        fi
        #check if the process is already running on another core
        if [ -e ${isRunning}/isRunning.${subj}.${postfix} ] ; then
                #skip if already in process
                echo "Skipping ${subj}: other process running" 
                continue
        fi
	touch ${isRunning}/isRunning.${subj}.${postfix}

	echo "RS input: ${subj_rs_bold}"
	echo "Mask file: ${subj_mask}"
	echo "rs_filename: ${rs_filename}"
	echo "filename_stem: ${filename_stem}"
	echo "Despiked out: ${subj_dspk_out}"
	echo "Motion corrected out: ${subj_mtcr_out}*"

	#check if the source files exist
	if [ -z "${subj_rs_bold}" ] || [ ! -e ${subj_rs_bold} ] ; then
		echo "File ${subj_rs_bold} does not exist" | tee -a ${isRunning}/isRunning.${subj}.${postfix}.err
        	rm ${isRunning}/isRunning.${subj}.${postfix}
		continue
	fi
	if [ ! -e ${subj_mask} ] ; then
		echo "Mask file ${subj_mask} does not exist" | tee -a ${isRunning}/isRunning.${subj}.${postfix}.err
        	rm ${isRunning}/isRunning.${subj}.${postfix}
		continue
	fi		
	#check if subjects motion correciton output directory exists, if not, make it
	if [ ! -e ${subj_outdir} ] ; then
		mkdir -p ${subj_outdir}
	fi

	#check if 3dDespike output exists already, if so, move on to regress.py
	if [ ! -e ${subj_dspk_out} ] ; then
		echo "Despiking BOLD timeseries: ${subj_rs_bold}"
		3dDespike -NEW -nomask -prefix ${subj_dspk_out} ${subj_rs_bold}
		despike_retval=$?
		if [ ! $despike_retval -eq 0 ]; then
			echo "3dDespike failed on ${subj_rs_bold}: return value $despike_retval \n(Probably too few TRs)" | tee -a ${isRunning}/isRunning.${subj}.${postfix}.err
			rm ${isRunning}/isRunning.${subj}.${postfix}
			continue
		fi

	fi
	echo "Running motion correction on ${subj_dspk_out}"
	python $regress_script -strategy ${strategy} -spikethr .5 -fwhm 5 -drop 5 -out $subj_mtcr_out ${subj_dspk_out} $subj_mask $subj_confounds
	

        #clean up isRunning file if you want
        rm ${isRunning}/isRunning.${subj}.${postfix}
done

