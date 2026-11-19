import os
import pathlib
import subprocess
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]
ROTATE = REPO / "tools/kscreen/gaokun-oobe-display-setup"


class OobeRotationTests(unittest.TestCase):
    def run_with_outputs(self, outputs):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output_args = root / "xrandr-args.txt"
            fake = root / "xrandr"
            fake.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = \"--query\" ]; then\n"
                "  printf '%s\\n' \"$XRANDR_OUTPUTS\"\n"
                "else\n"
                "  printf '%s\\n' \"$*\" > \"$XRANDR_ARGS\"\n"
                "fi\n"
            )
            fake.chmod(0o755)
            env = os.environ.copy()
            env.update(
                PATH=str(root) + os.pathsep + env.get("PATH", ""),
                XRANDR_OUTPUTS=outputs,
                XRANDR_ARGS=str(output_args),
            )
            run = subprocess.run(
                ["sh", str(ROTATE)],
                env=env,
                text=True,
                capture_output=True,
                timeout=5,
            )
            self.assertEqual(run.returncode, 0, run.stderr)
            return output_args.read_text().strip() if output_args.exists() else None

    def test_rotates_connected_internal_dsi(self):
        outputs = (
            "DSI-1 connected primary 1600x2560+0+0 (normal left inverted right x axis y axis)\n"
            "DP-1 connected 1920x1080+1600+0 (normal left inverted right x axis y axis)"
        )
        self.assertEqual(self.run_with_outputs(outputs), "--output DSI-1 --rotate right")

    def test_skips_disconnected_dsi_and_external_display(self):
        outputs = (
            "DSI-1 disconnected (normal left inverted right x axis y axis)\n"
            "DP-1 connected primary 1920x1080+0+0"
        )
        self.assertIsNone(self.run_with_outputs(outputs))

    def test_skips_no_internal_connector(self):
        self.assertIsNone(self.run_with_outputs("HDMI-1 connected primary 1920x1080+0+0"))


if __name__ == "__main__":
    unittest.main()
