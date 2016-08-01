#!/bin/bash

DATETIME=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
LOG_DIR_BASE=logs/$DATETIME
mkdir -p $LOG_DIR_BASE

# Parse the additional args later passed to `obspy-runtests` in
# the docker images.
extra_args=""
while getopts "t:e:" opt; do
    case "$opt" in
    e)  extra_args=', "'$OPTARG'"'
        ;;
    t)  TARGET=(${OPTARG//:/ })
        REPO=${TARGET[0]}
        SHA=${TARGET[1]}
        TARGET=true
        OBSPY_DOCKER_TEST_SOURCE_TREE="clone"
        ;;
    esac
done

# This bracket is closed at the very end and causes a redirection of everything
# to the logfile as well as stdout.
{
# Delete all but the last 15 log directories. The `+16` is intentional. Fully
# POSIX compliant version adapted from http://stackoverflow.com/a/34862475/1657047
ls -tp logs | tail -n +16 | xargs -I % rm -rf -- logs/%

OBSPY_PATH=$(dirname $(dirname $(pwd)))

# Remove all test images stored locally. Otherwise they'll end up on the
# images.
rm -rf $OBSPY_PATH/obspy/core/tests/images/testrun
rm -rf $OBSPY_PATH/obspy/imaging/tests/images/testrun
rm -rf $OBSPY_PATH/obspy/station/tests/images/testrun

DOCKERFILE_FOLDER=base_images
TEMP_PATH=temp
NEW_OBSPY_PATH=$TEMP_PATH/obspy

# Determine the docker binary name. The official debian packages use docker.io
# for the binary's name due to some legacy docker package.
DOCKER=`which docker.io || which docker`

# Execute Python once and import ObsPy to trigger building the RELEASE-VERSION
# file.
python -c "import obspy"

# Create temporary folder.
rm -rf $TEMP_PATH
mkdir -p $TEMP_PATH

# Copy ObsPy to the temp path. This path is the execution context of the Docker images.
mkdir -p $NEW_OBSPY_PATH
# depending on env variable OBSPY_DOCKER_TEST_SOURCE_TREE ("cp" or "clone")
# we either copy the obspy tree (potentially with local changes) or
# `git clone` from it for a tree free of local changes
if [ ! "$OBSPY_DOCKER_TEST_SOURCE_TREE" ]
then
    # default to "cp" to not change default behavior
    OBSPY_DOCKER_TEST_SOURCE_TREE="cp"
fi
if [ "$OBSPY_DOCKER_TEST_SOURCE_TREE" == "cp" ]
then
    cp -r $OBSPY_PATH/obspy $NEW_OBSPY_PATH/obspy/
    cp $OBSPY_PATH/setup.py $NEW_OBSPY_PATH/setup.py
    cp $OBSPY_PATH/MANIFEST.in $NEW_OBSPY_PATH/MANIFEST.in
    rm -f $NEW_OBSPY_PATH/obspy/lib/*.so
elif [ "$OBSPY_DOCKER_TEST_SOURCE_TREE" == "clone" ]
then
    git clone file://$OBSPY_PATH $NEW_OBSPY_PATH
    if [ "$TARGET" = true ] ; then
        git remote add TEMP git://github.com/$REPO/obspy
        git fetch TEMP
        git checkout $SHA
        git remote remove TEMP
        git clean -fdx
        git status
    fi
    # we're cloning so we have a non-dirty version actually
    cat $OBSPY_PATH/obspy/RELEASE-VERSION | sed 's#\.dirty$##' > $NEW_OBSPY_PATH/obspy/RELEASE-VERSION
else
    echo "Bad value for OBSPY_DOCKER_TEST_SOURCE_TREE: $OBSPY_DOCKER_TEST_SOURCE_TREE"
    exit 1
fi
FULL_VERSION=`cat $NEW_OBSPY_PATH/obspy/RELEASE-VERSION`
COMMIT=`cd $OBSPY_PATH && git log -1 --pretty=format:%H`

# Copy the install script.
cp scripts/install_and_run_tests_on_image.sh $TEMP_PATH/install_and_run_tests_on_image.sh


# Helper function checking if an element is in an array.
list_not_contains() {
    for word in $1; do
        [[ $word == $2 ]] && return 1
    done
    return 0
}


# Function creating an image if it does not exist.
create_image () {
    image_name=$1;
    has_image=$($DOCKER images | grep obspy | grep $image_name)
    if [ "$has_image" ]; then
        printf "\e[101m\e[30m  >>> Image '$image_name' already exists.\e[0m\n"
    else
        printf "\e[101m\e[30m  Image '$image_name' will be created.\e[0m\n"
        $DOCKER build -t obspy:$image_name $image_path
    fi
}


# Function running test on an image.
run_tests_on_image () {
    image_name=$1;
    printf "\n\e[101m\e[30m  >>> Running tests for image '"$image_name"'...\e[0m\n"
    # Copy dockerfile and render template.
    sed "s/{{IMAGE_NAME}}/$image_name/g; s/{{EXTRA_ARGS}}/$extra_args/g" scripts/Dockerfile_run_tests.tmpl > $TEMP_PATH/Dockerfile

    # Where to save the logs, and a random ID for the containers.
    LOG_DIR=${LOG_DIR_BASE}/$image_name
    mkdir -p $LOG_DIR
    ID=$RANDOM-$RANDOM-$RANDOM

    $DOCKER build -t temp:temp $TEMP_PATH

    $DOCKER run --name=$ID temp:temp

    $DOCKER cp $ID:/INSTALL_LOG.txt $LOG_DIR
    $DOCKER cp $ID:/TEST_LOG.txt $LOG_DIR
    $DOCKER cp $ID:/failure $LOG_DIR
    $DOCKER cp $ID:/success $LOG_DIR

    $DOCKER cp $ID:/obspy/obspy/imaging/tests/images/testrun $LOG_DIR/imaging_testrun
    $DOCKER cp $ID:/obspy/obspy/core/tests/images/testrun $LOG_DIR/core_testrun
    $DOCKER cp $ID:/obspy/obspy/station/tests/images/testrun $LOG_DIR/station_testrun

    mkdir -p $LOG_DIR/test_images

    mv $LOG_DIR/imaging_testrun/testrun $LOG_DIR/test_images/imaging
    mv $LOG_DIR/core_testrun/testrun $LOG_DIR/test_images/core
    mv $LOG_DIR/station_testrun/testrun $LOG_DIR/test_images/station

    rm -rf $LOG_DIR/imaging_testrun
    rm -rf $LOG_DIR/core_testrun
    rm -rf $LOG_DIR/station_testrun

    $DOCKER rm $ID
    $DOCKER rmi temp:temp
}


# 1. Build all the base images if they do not yet exist.
printf "\e[44m\e[30mSTEP 1: CREATING BASE IMAGES\e[0m\n"

for image_path in $DOCKERFILE_FOLDER/*; do
    image_name=$(basename $image_path)
    if [ $# != 0 ]; then
        if list_not_contains "$*" $image_name; then
            continue
        fi
    fi
    create_image $image_name;
done


# 2. Execute the ObsPy
printf "\n\e[44m\e[30mSTEP 2: EXECUTING THE TESTS\e[0m\n"

# Loop over all ObsPy Docker images.
for image_name in $($DOCKER images | grep obspy | awk '{print $2}'); do
    if [ $# != 0 ]; then
        if list_not_contains "$*" $image_name; then
            continue
        fi
    fi
    run_tests_on_image $image_name;
done

# set commit status
# helper function to determine overall success/failure across all images
# env variable OBSPY_COMMIT_STATUS_TOKEN has to be set for authorization
overall_status() {
    ls ${LOG_DIR_BASE}/*/failure 2>&1 > /dev/null && return 1
    ls ${LOG_DIR_BASE}/*/success 2>&1 > /dev/null && return 0
    return 1
}
# encode parameter part of the URL, using requests as it is installed anyway..
# (since we use python to import obspy to generate RELEASE-VERSION above)
# it's just looking up the correct quoting function from urllib depending on
# py2/3 and works with requests >= 1.0 (which is from 2012)
FULL_VERSION_URLENCODED=`python -c "from requests.compat import quote; print(quote(\"${FULL_VERSION}\"))"`
COMMIT_STATUS_TARGET_URL="http://tests.obspy.org/?version=${FULL_VERSION_URLENCODED}"
if overall_status ;
then
    COMMIT_STATUS=success
    COMMIT_STATUS_DESCRIPTION="Docker tests succeeded:"
else
    COMMIT_STATUS=failed
    COMMIT_STATUS_DESCRIPTION="Docker tests failed:"
fi
curl -H "Content-Type: application/json" -H "Authorization: token ${OBSPY_COMMIT_STATUS_TOKEN}" --request POST --data "{\"state\": \"${COMMIT_STATUS}\", \"context\": \"docker-testbot\", \"description\": \"${COMMIT_STATUS_DESCRIPTION}\", \"target_url\": \"${COMMIT_STATUS_TARGET_URL}\"}" https://api.github.com/repos/obspy/obspy/statuses/${COMMIT}

rm -rf $TEMP_PATH

} 2>&1 | tee -a $LOG_DIR_BASE/docker.log
