#!/usr/bin/env python3
"""Static checks for ios-build.yml. No GitHub and no secrets."""
import difflib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = (ROOT / ".github/workflows/ios-build.yml").read_text()
FIXTURES = ROOT / "tests/fixtures/step-bodies"


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def extract_steps(text):
    lines = text.splitlines(True)
    steps = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("      - name: ") or line.startswith("      - uses:"):
            name = line.split(": ", 1)[1].strip() if line.startswith("      - name: ") else line.strip()
            j = i + 1
            iff = None
            body = None
            while j < len(lines) and not (
                lines[j].startswith("      - name: ") or lines[j].startswith("      - uses:")
            ):
                if lines[j].startswith("        if: "):
                    iff = lines[j].split("if: ", 1)[1].strip()
                if lines[j].startswith("        run: |"):
                    k = j + 1
                    buff = []
                    while k < len(lines) and (
                        lines[k].startswith("          ") or lines[k].strip() == ""
                    ):
                        if (
                            lines[k].startswith("        ")
                            and not lines[k].startswith("          ")
                            and lines[k].strip() != ""
                        ):
                            break
                        if (
                            lines[k].strip() == ""
                            and k + 1 < len(lines)
                            and lines[k + 1].startswith("      - ")
                        ):
                            break
                        if lines[k].startswith("          "):
                            buff.append(lines[k][10:])
                        else:
                            buff.append("\n")
                        k += 1
                    body = "".join(buff)
                    j = k
                    continue
                j += 1
            steps.append({"name": name, "if": iff, "run": body})
            i = j
            continue
        i += 1
    return steps


def heredoc(body, marker):
    open_line = f"bash -s <<'{marker}'\n"
    if open_line not in body:
        fail(f"missing heredoc {marker}")
    start = body.index(open_line) + len(open_line)
    close = f"\n{marker}\n"
    end = body.index(close, start)
    return body[start:end] + "\n"


def main():
    if "permissions: {}" not in WF:
        fail("permissions: {} was removed")
    if "contents: read" in WF or "contents: write" in WF:
        fail("workflow token permissions widened")

    for slot in [f"APP{n}" for n in range(1, 11)]:
        if slot not in WF.split("options:", 1)[1].split("\n", 1)[0]:
            fail(f"missing slot {slot}")
    if "default: APP1" not in WF:
        fail("default slot changed")
    if "default: true" not in WF.split("upload:", 1)[1].split("compile_only:", 1)[0]:
        fail("upload default changed")
    compile_block = WF.split("compile_only:", 1)[1].split("compile_destination:", 1)[0]
    if "default: false" not in compile_block:
        fail("compile_only must default false")
    if "default: ios" not in WF.split("compile_destination:", 1)[1].split("permissions:", 1)[0]:
        fail("compile_destination default")

    # No secret material is accepted as a dispatch input.
    inputs = WF.split("inputs:", 1)[1].split("permissions:", 1)[0]
    for banned in ("token", "password", "private_key", "p12", "secret"):
        if banned in inputs.lower():
            fail(f"dispatch inputs mention {banned}")

    steps = extract_steps(WF)
    by_name = {}
    for step in steps:
        by_name.setdefault(step["name"], []).append(step)

    def one(name):
        found = by_name.get(name, [])
        if len(found) != 1:
            fail(f"expected one step {name}, found {len(found)}")
        return found[0]

    expected_if = {
        "Checkout source": "${{ env.SOURCE_KIND != 'origin' }}",
        "Checkout Origin source": "${{ env.SOURCE_KIND == 'origin' }}",
        "Signing setup": "${{ !inputs.compile_only }}",
        "Configure signing": "${{ env.NATIVE != '1' && !inputs.compile_only }}",
        "Archive": "${{ env.NATIVE != '1' && !inputs.compile_only }}",
        "Native project": "${{ env.NATIVE == '1' && !inputs.compile_only }}",
        "Archive (native)": "${{ env.NATIVE == '1' && !inputs.compile_only }}",
        "Compile (native)": "${{ env.NATIVE == '1' && inputs.compile_only }}",
        "Compile": "${{ env.NATIVE != '1' && inputs.compile_only }}",
        "Export IPA": "${{ !inputs.compile_only }}",
        "Upload to TestFlight": "${{ inputs.upload && !inputs.compile_only }}",
    }
    for name, iff in expected_if.items():
        step = one(name)
        if step["if"] != iff:
            fail(f"{name} if is {step['if']!r}, want {iff!r}")

    identical = {
        "Checkout source": "checkout-source.sh",
        "Signing setup": "signing-setup.sh",
        "Configure signing": "configure-signing.sh",
        "Archive": "archive-expo.sh",
        "Native project": "native-project.sh",
        "Archive (native)": "archive-native.sh",
        "Export IPA": "export-ipa.sh",
        "Upload to TestFlight": "upload-testflight.sh",
    }
    for name, fixture in identical.items():
        got = one(name)["run"]
        want = (FIXTURES / fixture).read_text()
        if got != want:
            diff = "".join(
                difflib.unified_diff(
                    want.splitlines(True),
                    got.splitlines(True),
                    fromfile=fixture,
                    tofile=name,
                )
            )
            fail(f"signed step changed: {name}\n{diff}")

    prepare = one("Prepare")["run"]
    old_prepare = (FIXTURES / "prepare.sh").read_text()
    prefix = old_prepare[: -len('echo "✔ ok"\n')]
    if prefix not in prepare:
        fail("prepare lost the original slot setup")
    if 'SOURCE_KIND=github' not in prepare or 'SOURCE_KIND=origin' not in prepare:
        fail("prepare does not select source kind")
    if "slot not configured" not in prepare or "invalid build number" not in prepare:
        fail("prepare validation changed")

    cleanup = one("Cleanup")["run"]
    old_cleanup = (FIXTURES / "cleanup.sh").read_text()
    for line in old_cleanup.splitlines():
        if line.startswith("echo "):
            continue
        if line not in cleanup:
            fail(f"cleanup lost line: {line}")
    if 'rm -rf "$RUNNER_TEMP/src"' not in cleanup or "origin-auth" not in cleanup:
        fail("cleanup does not remove the private checkout and origin token dir")
    if "security delete-keychain" not in cleanup:
        fail("cleanup no longer deletes the signing keychain")

    native = one("Native project")["run"]
    for needle in (
        "WATCH_BUNDLE_ID",
        "WATCH_PROFILE_UUID",
        "EXT_BUNDLE_ID",
        "watchapp2",
        "watchos",
        "iPhone Distribution",
        'generic/platform=#{(ios || !watch) ? "iOS" : "watchOS"}',
    ):
        if needle not in native:
            fail(f"native signing lost {needle}")

    signing = one("Signing setup")["run"]
    for needle in ("WATCH_PROFILE_B64", "EXT_PROFILE_B64", "PROFILE_B64", "security import"):
        if needle not in signing:
            fail(f"signing setup lost {needle}")

    archive = one("Archive (native)")["run"]
    if "OTHER_CODE_SIGN_FLAGS" not in archive or " archive" not in archive:
        fail("native archive no longer signs")
    if "CODE_SIGNING_ALLOWED" in archive or "compile_destination" in archive:
        fail("native archive started reading compile-only settings")

    origin_body = one("Checkout Origin source")["run"]
    embedded = heredoc(origin_body, "ORIGIN_CHECKOUT_EOF")
    script = (ROOT / "scripts/origin-checkout.sh").read_text()
    if embedded != script:
        fail("origin checkout embedded in the workflow drifted from scripts/origin-checkout.sh")
    for needle in (
        'repository:contents:read',
        "origin.cursor.com",
        "submodule update --init --recursive",
        "160000",
        "CODE_SIGNING_ALLOWED",
    ):
        if needle == "CODE_SIGNING_ALLOWED":
            if needle in script:
                fail("origin checkout must not sign")
            continue
        if needle not in script:
            fail(f"origin checkout missing {needle}")
    for banned in (
        "repository:contents:write",
        "repository:mirror",
        "x-access-token:${",
        "x-access-token:$",
        "clone-fast",
        "syncMirror",
        "CURSOR_AUTH_TOKEN=",
    ):
        if banned in script:
            fail(f"origin checkout contains {banned}")

    for step_name in ("Compile (native)", "Compile"):
        body = one(step_name)["run"]
        embedded_c = heredoc(body, "COMPILE_ONLY_EOF")
        compile_script = (ROOT / "scripts/compile-only.sh").read_text()
        if embedded_c != compile_script:
            fail(f"{step_name} drifted from scripts/compile-only.sh")
    compile_script = (ROOT / "scripts/compile-only.sh").read_text()
    if "CODE_SIGNING_ALLOWED=NO" not in compile_script or "CODE_SIGNING_REQUIRED=NO" not in compile_script:
        fail("compile-only does not disable signing")
    if " generic/platform=" not in compile_script and "generic/platform=" not in compile_script:
        fail("compile-only missing generic destination")
    for banned in (
        "iPhone Distribution",
        "mobileprovision",
        "altool",
        "simctl",
        "exportArchive",
        "security import",
        "xcodebuild test",
        " archive",
    ):
        if banned in compile_script:
            fail(f"compile-only contains {banned}")

    # Signing secrets stay on the signing step only.
    origin_step = WF.split("- name: Checkout Origin source", 1)[1].split("- name: Select Xcode", 1)[0]
    for banned in ("IOS_DIST_P12", "ASC_KEY", "APPLE_TEAM_ID", "PROFILE_B64", "DEPLOY_KEY"):
        if banned in origin_step:
            fail(f"origin checkout reads {banned}")
    compile_section = WF.split("- name: Compile (native)", 1)[1].split("- name: Export IPA", 1)[0]
    for banned in ("IOS_DIST_P12", "ASC_KEY", "APPLE_TEAM_ID", "PROFILE_B64", "ORIGIN_APP_PRIVATE_KEY"):
        if banned in compile_section:
            fail(f"compile step reads {banned}")

    artifact = WF.split("actions/upload-artifact", 1)[1].split("retention-days:", 1)[0]
    if "enclog" not in artifact:
        fail("encrypted log artifact path changed")
    if "/src" in artifact or "xcodebuild.out" in artifact:
        fail("artifact would publish source or a plaintext build log")

    # Expo/node gates stay tied to NATIVE only, so a signed Expo slot still prebuilds.
    for name in ("Install JS dependencies", "Expo prebuild", "Pod install"):
        step = one(name)
        if step["if"] != "${{ env.NATIVE != '1' }}":
            fail(f"{name} condition changed: {step['if']}")

    print("workflow static checks ok")


if __name__ == "__main__":
    main()
