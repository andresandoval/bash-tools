#!/usr/bin/env bash
#
# mvnb — build and install one module of a Maven multimodule project, together
# with the modules it depends on.
#
#   mvnb my-service                     mvn -pl my-service -am clean install -DskipTests
#   mvnb my-service -DskipTests=false   the same, but run the tests
#
# It runs Maven in the current directory, which has to be the reactor root — the
# directory with the aggregator pom.xml. That is where -pl resolves module names
# from. Everything after MODULE goes to Maven untouched.
#
# It is a shell function rather than a tools/ script only so its tab-completion
# can live in the same file.

# ---------------------------------------------------------------------------
# Internals — prefixed `_mvnb_`, not meant to be called directly.
# ---------------------------------------------------------------------------

# Print usage. Callers send it to stdout on --help, to stderr on a usage error.
_mvnb_help() {
    cat <<'EOF'
Usage:
  mvnb MODULE [MVN_ARG...]
  mvnb [-h|--help]

Description:
  Build and install one module of a Maven multimodule project together with the
  modules it depends on. Shorthand for:

    mvn -pl MODULE -am clean install -DskipTests [MVN_ARG...]

  Run it from the reactor root — the directory holding the aggregator pom.xml.

  MODULE is anything -pl accepts: a module name, a path (services/my-service),
  or :artifact-id. It is tab-completed from the <module> entries of ./pom.xml.

  MVN_ARG... goes to Maven unchanged, after the defaults. Maven keeps the last
  value of a repeated -D, so an argument here overrides a default.

  Uses ./mvnw when the project has an executable one, otherwise mvn.

Examples:
  mvnb my-service                     build my-service and its dependencies
  mvnb my-service -DskipTests=false   the same, but run the tests
  mvnb my-service -o -Pdev            offline, with the dev profile
  mvnb :my-artifact -X                by artifact id, with debug output
EOF
}

# The Maven command to call: the project's wrapper when it has one, so a build
# uses the Maven version the project pins.
_mvnb_command() {
    if [ -x ./mvnw ]; then
        printf './mvnw'
    else
        printf 'mvn'
    fi
}

# Top-level module names, one per line, read out of ./pom.xml. Reading XML with
# sed is good enough here: <module> tags sit one per line in every pom people
# write, and a name it misses costs a tab-completion, never a build.
_mvnb_modules() {
    [ -f ./pom.xml ] || return 0
    sed -n 's:.*<module>\(.*\)</module>.*:\1:p' ./pom.xml
}

# ---------------------------------------------------------------------------
# mvnb — the command.
# ---------------------------------------------------------------------------

mvnb() {
    local module

    case "${1-}" in
        -h | --help)
            _mvnb_help
            return 0
            ;;
        "")
            echo "mvnb: no module given" >&2
            _mvnb_help >&2
            return 1
            ;;
    esac

    # The module has to come first. Without this, `mvnb -Pdev my-service` would
    # reach Maven as `-pl -Pdev`, which fails much further away from the cause.
    case "$1" in
        -*)
            printf 'mvnb: the first argument is the module, not an option (got %s)\n' "$1" >&2
            printf 'Usage: mvnb MODULE [MVN_ARG...]\n' >&2
            return 1
            ;;
    esac

    module="$1"
    shift

    # -pl and -am only mean anything at the reactor root. Say so here, rather
    # than let Maven report a module it cannot find.
    if [ ! -f ./pom.xml ]; then
        printf 'mvnb: no pom.xml in %s — run it from the reactor root\n' "$PWD" >&2
        return 1
    fi

    local -a cmd
    cmd=("$(_mvnb_command)" -pl "$module" -am clean install -DskipTests "$@")

    # Echo the command: the defaults are invisible otherwise, and a build that
    # skipped the tests should never be a surprise.
    printf '+'
    printf ' %q' "${cmd[@]}"
    printf '\n'

    "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# Tab-completion: module names from ./pom.xml, for the first word only. After
# that the arguments are Maven's own, and we do not try to complete those.
# ---------------------------------------------------------------------------

_mvnb_complete() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=()

    if [ "$COMP_CWORD" -gt 1 ]; then
        return 0
    fi

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--help" -- "$cur"))
        return 0
    fi

    COMPREPLY=($(compgen -W "$(_mvnb_modules | tr '\n' ' ')" -- "$cur"))
}

complete -F _mvnb_complete mvnb
