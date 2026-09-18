#!/usr/bin/env python3
"""Check a fresh protemu ASIC bundle and rerun the existing TT wrapper trace."""

import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def lock_values(path):
    return dict(
        line.split("=", 1)
        for line in path.read_text().splitlines()
        if line and not line.startswith("#")
    )


def check_bundle(root, bundle):
    manifest = json.loads((bundle / "manifest.json").read_text())
    config = json.loads((bundle / "src/config.json").read_text())
    lock = lock_values(root / "tinytapeout/asic-dependencies.lock")
    assert manifest["source_revision"] == subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    assert manifest["top_module"] == "tt_um_leemperor_hardcaml_protemu"
    assert manifest["project"] == "protemu_observable"
    assert manifest["requested_tools"] == {
        "support_tools_revision": lock["support_tools_revision"],
        "pdk_revision": lock["pdk_revision"],
        "librelane": lock["librelane_version"],
        "python": lock["python"],
    }
    assert manifest["synthesis_sources"] == [
        "src/tt_um_leemperor_hardcaml_protemu.v"
    ]
    assert manifest["simulation_sources"] == [
        "simulation/tt_um_leemperor_hardcaml_protemu.v"
    ]
    assert config["CLOCK_PORT"] == "clk"
    assert abs(config["CLOCK_PERIOD"] - 1e9 / 48e6) < 1e-10
    assert config["DESIGN_NAME"] == manifest["top_module"]
    assert config["VERILOG_FILES"] == [
        "dir::tt_um_leemperor_hardcaml_protemu.v"
    ]
    assert config["PNR_SDC_FILE"] == "dir::../constraints/top.sdc"
    assert config["SIGNOFF_SDC_FILE"] == "dir::../constraints/top.sdc"
    assert "tt_block_6x4_pgvdd.def" in config["FP_DEF_TEMPLATE"]
    info = (bundle / "info.yaml").read_text()
    assert 'tiles: "6x4"' in info
    assert 'top_module: "tt_um_leemperor_hardcaml_protemu"' in info
    assert '"P0 command valid"' in info
    assert "create_clock -name clk" in (bundle / "constraints/top.sdc").read_text()
    source_paths = {item["path"] for item in manifest["source_inputs"]}
    assert {
        "bin/asic_bundle.ml",
        "lib/p0_observable.ml",
        "tinytapeout/asic-dependencies.lock",
    } <= source_paths
    for item in manifest["source_inputs"]:
        source = root / item["path"]
        copied = bundle / "inputs" / item["path"]
        assert copied.read_bytes() == source.read_bytes()
    for item in manifest["files"]:
        path = bundle / item["path"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"]
    return manifest["identity"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata-only", action="store_true")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    emitter = root / "_build/default/bin/asic_bundle.exe"
    run(str(emitter), "--check-conflicts", cwd=root)
    with tempfile.TemporaryDirectory(prefix="protemu-adopted-") as scratch:
        scratch = pathlib.Path(scratch)
        first, second = scratch / "first", scratch / "second"
        run(str(emitter), str(first), str(root), cwd=root)
        run(str(emitter), str(second), str(root), cwd=root)
        assert check_bundle(root, first) == check_bundle(root, second)
        assert (first / "manifest.json").read_bytes() == (
            second / "manifest.json"
        ).read_bytes()
        print("PASS repeatable bundle, manifest, metadata, and conflict checks")
        if args.metadata_only:
            return
        image = "ghcr.io/librelane/librelane:" + lock_values(
            root / "tinytapeout/asic-dependencies.lock"
        )["librelane_version"]
        try:
            image_id = subprocess.check_output(
                ["docker", "image", "inspect", "--format", "{{.Id}}", image],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (FileNotFoundError, subprocess.CalledProcessError) as error:
            raise SystemExit(
                f"pinned LibreLane image unavailable: {image}; "
                f"install Docker and run 'docker pull {image}'"
            ) from error
        commands = "\n".join([
            "iverilog -g2012 -Wall -Wno-timescale -s tb -o /tmp/protemu-wrapper /bundle/src/tt_um_leemperor_hardcaml_protemu.v /test/tb.v",
            "vvp /tmp/protemu-wrapper",
            "verilator --lint-only --top-module tt_um_leemperor_hardcaml_protemu -Wno-DECLFILENAME /bundle/src/tt_um_leemperor_hardcaml_protemu.v",
            "yosys -q -p 'read_verilog /bundle/src/tt_um_leemperor_hardcaml_protemu.v; hierarchy -check -top tt_um_leemperor_hardcaml_protemu; synth -top tt_um_leemperor_hardcaml_protemu; stat'",
        ])
        run(
            "docker", "run", "--rm", "--pull=never", "--network", "none",
            "-v", f"{first}:/bundle:ro",
            "-v", f"{root / 'tinytapeout/test'}:/test:ro",
            "--entrypoint", "sh", image, "-ec", commands,
        )
        print(f"PASS emitted RTL wrapper trace, lint, and synthesis ({image_id})")


if __name__ == "__main__":
    main()
