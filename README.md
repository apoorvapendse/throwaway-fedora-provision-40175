Throwaway public repo for one GitHub Actions run of Zulip `./tools/provision` on Fedora 43 x86_64.

The job uses a free `ubuntu-latest` runner (public repository) and a privileged Fedora container. It checks that current `main` fails to build `pyicu` because `g++` is missing, then adds `gcc-c++` to `COMMON_YUM_VENV_DEPENDENCIES` and runs provision again.

This is not a patch to zulip/zulip. See https://github.com/zulip/zulip/pull/40175.
