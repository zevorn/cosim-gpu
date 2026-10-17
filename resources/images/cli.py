# SPDX-License-Identifier: Apache-2.0

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from .builder import (
    build_profile,
    inspect_profile,
    profile_fingerprint,
    validate_profile,
    verify_profile,
)
from .errors import ImageError
from .profile import ProfileError, list_profiles, load_profile


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build and verify guest image profiles"
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=Path(os.environ.get("COSIM_WORKSPACE", Path.cwd())),
    )
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("list", help="list available image profiles")
    inspect = commands.add_parser(
        "inspect",
        help="show profile inputs and cache status",
    )
    inspect.add_argument("profile")
    inspect.add_argument("--json", action="store_true")
    inspect.add_argument("--write-verification-cache", action="store_true")
    key = commands.add_parser("key", help="print the profile build identity")
    key.add_argument("profile")
    validate = commands.add_parser(
        "validate",
        help="validate the profile and Packer configuration",
    )
    validate.add_argument("profile")
    validate.add_argument("--syntax-only", action="store_true")
    build = commands.add_parser(
        "build",
        help="build or reuse a verified image bundle",
    )
    build.add_argument("profile")
    verify = commands.add_parser(
        "verify",
        help="verify an existing image bundle",
    )
    verify.add_argument("profile")
    verify.add_argument("--expected-key")
    arguments = parser.parse_args()
    workspace = arguments.workspace.resolve()
    try:
        if arguments.operation == "list":
            for identifier in list_profiles(workspace):
                profile = load_profile(workspace, identifier)
                print(
                    f"{identifier}\t{profile.distribution} "
                    f"{profile.release}\t{profile.architecture}"
                )
        elif arguments.operation == "inspect":
            state = inspect_profile(
                workspace,
                arguments.profile,
                cache_verification=arguments.write_verification_cache,
            )
            if arguments.json:
                print(json.dumps(state, sort_keys=True))
            else:
                print(json.dumps(state, indent=2, sort_keys=True))
        elif arguments.operation == "key":
            print(
                profile_fingerprint(workspace, arguments.profile)["input_key"]
            )
        elif arguments.operation == "validate":
            validate_profile(
                workspace,
                arguments.profile,
                syntax_only=arguments.syntax_only,
            )
        elif arguments.operation == "build":
            result = build_profile(workspace, arguments.profile)
            print(json.dumps(result, sort_keys=True))
        else:
            manifest = verify_profile(
                workspace,
                arguments.profile,
                arguments.expected_key,
            )
            print(
                json.dumps(
                    {"status": "PASS", "input_key": manifest["input_key"]},
                    sort_keys=True,
                )
            )
    except (
        ImageError,
        ProfileError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"cosim-image: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
