#!/bin/bash

## Deploy virualenv for testing enironment molecule/ansible-playbook/infratest

## Shell Opts ----------------------------------------------------------------

set -x
set -o pipefail
export ANSIBLE_HOST_KEY_CHECKING=False

## Variables -----------------------------------------------------------------

# RC is a sentinel value to capture failed exit codes of portions of the script
RC=0
SYS_VENV_NAME="${SYS_VENV_NAME:-venv-molecule}"
SYS_CONSTRAINTS="constraints.txt"
SYS_REQUIREMENTS="requirements.txt"
SYS_INVENTORY="${SYS_INVENTORY:-/opt/openstack-ansible/playbooks/inventory}"

## Functions -----------------------------------------------------------------
# Update the RC return code value unless it has previously been set to a
# non-zero value.
update_return_code() {
    if [ "$RC" -eq "0" ]; then
        RC=$1
    fi
}

# Return the RC return code value unless it has not previously been set.
# If that is the case, pass through the exit code of the last call.
my_exit() {
    if [ "$RC" -eq "0" ]; then
        exit $1
    else
        exit $RC
    fi
}

## Main ----------------------------------------------------------------------

# Trap script termination to return a captured RC value without prematurely
# terminating the script.
trap 'my_exit $?' INT TERM EXIT

# fail hard during setup
set -e
# Create virtualenv for molecule
virtualenv --no-pip --no-setuptools --no-wheel "${SYS_VENV_NAME}"

# Activate virtualenv
source "${SYS_VENV_NAME}/bin/activate"

# Ensure that correct pip version is installed
PIP_TARGET="$(awk -F= '/^pip==/ {print $3}' ${SYS_CONSTRAINTS})"
VENV_PYTHON="${SYS_VENV_NAME}/bin/python"
VENV_PIP="${SYS_VENV_NAME}/bin/pip"

if [[ "$(${VENV_PIP} --version)" != "pip ${PIP_TARGET}"* ]]; then
    CURL_CMD="curl --silent --show-error --retry 5"
    OUTPUT_FILE="get-pip.py"
    ${CURL_CMD} https://bootstrap.pypa.io/get-pip.py > ${OUTPUT_FILE}  \
        || ${CURL_CMD} https://raw.githubusercontent.com/pypa/get-pip/master/get-pip.py > ${OUTPUT_FILE}
    GETPIP_OPTIONS="pip setuptools wheel --constraint ${SYS_CONSTRAINTS}"
    ${VENV_PYTHON} ${OUTPUT_FILE} ${GETPIP_OPTIONS} \
        || ${VENV_PYTHON} ${OUTPUT_FILE} --isolated ${GETPIP_OPTIONS}
fi

# Install test suite requirements
PIP_OPTIONS="-r ${SYS_REQUIREMENTS}"
${VENV_PIP} install ${PIP_OPTIONS} || ${VENV_PIP} install --isolated ${PIP_OPTIONS}

# Generate moleculerized inventory from openstack-ansible dynamic inventory
if [[ -n "${MNAIO_SSH}" ]]; then
    ${MNAIO_SSH} "${SYS_INVENTORY}/dynamic_inventory.py" > dynamic_inventory.json
else
    ${SYS_INVENTORY}/dynamic_inventory.py > dynamic_inventory.json
fi

# Run molecule converge and verify
# for each submodule in ${SYS_TEST_SOURCE}/molecules
set +e # allow test stages to return errors
for TEST in molecules/* ; do
    ./moleculerize.py --output "$TEST/molecule/default/molecule.yml" dynamic_inventory.json
    pushd "$TEST"
    echo "TESTING: $(git remote -v | awk '/fetch/{print $2}') at SHA $(git rev-parse HEAD)"
    molecule converge
    molecule verify
    update_return_code $?
    popd
done

# Gather junit.xml results
rm -f test_results.tar  # ensure any previous results are deleted
ls  molecules/*/molecule/*/*.xml | tar -cvf test_results.tar --files-from=-
