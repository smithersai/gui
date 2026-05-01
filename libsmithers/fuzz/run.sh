#!/usr/bin/env sh
set -eu

IMAGE_NAME="${LIBSMITHERS_FUZZ_IMAGE:-libsmithers-fuzz}"
TARGETS="slash cwd client persistence action palette models event"

if [ "${LIBSMITHERS_FUZZ_IN_DOCKER:-0}" != "1" ]; then
    docker build -t "${IMAGE_NAME}" .
    docker run --rm "${IMAGE_NAME}" ./run.sh "$@"
    exit 0
fi

mode="${1:---short}"
case "${mode}" in
    --short)
        seconds="${LIBSMITHERS_FUZZ_SHORT_SECONDS:-30}"
        ;;
    --long)
        seconds="${LIBSMITHERS_FUZZ_LONG_SECONDS:-600}"
        ;;
    *)
        echo "usage: ./run.sh [--short|--long]" >&2
        exit 2
        ;;
esac

zig build

for target in ${TARGETS}; do
    log="fuzz-${target}.log"
    echo "==> fuzzing ${target} for ${seconds}s"
    set +e
    timeout "${seconds}s" zig build "run-${target}" --fuzz --summary none >"${log}" 2>&1
    status=$?
    set -e

    cat "${log}"

    if [ "${status}" -eq 124 ] || [ "${status}" -eq 143 ]; then
        echo "==> ${target}: completed timebox without reported crash"
        continue
    fi

    if [ "${status}" -ne 0 ]; then
        timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
        crash_dir="crashes/${target}/${timestamp}"
        mkdir -p "${crash_dir}"
        cp "${log}" "${crash_dir}/fuzz.log"
        input_path="$(find .zig-cache -path '*/f/*' -type f 2>/dev/null | sort | tail -n 1 || true)"
        if [ -n "${input_path}" ] && [ -f "${input_path}" ]; then
            cp "${input_path}" "${crash_dir}/input.bin"
            input_note="Captured newest Zig fuzzer corpus input: ${input_path}"
        else
            input_note="No current Zig fuzzer input file was found in .zig-cache."
        fi
        {
            echo "# ${target} fuzz crash"
            echo
            echo "- Target: ${target}"
            echo "- UTC timestamp: ${timestamp}"
            echo "- Exit status: ${status}"
            echo "- ${input_note}"
            echo
            echo "## Command"
            echo
            echo '```sh'
            echo "timeout ${seconds}s zig build run-${target} --fuzz --summary none"
            echo '```'
            echo
            echo "## Log"
            echo
            echo '```text'
            cat "${log}"
            echo '```'
        } >"${crash_dir}/report.md"
        echo "crash details written to ${crash_dir}" >&2
        exit "${status}"
    fi

    echo "==> ${target}: exited cleanly"
done
