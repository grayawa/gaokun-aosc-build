import pathlib
import subprocess
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]
HELPER = REPO / "scripts/ci/lib/merge_firmware.sh"


class FirmwareMergeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = pathlib.Path(self.temp.name)
        self.src = base / "source"
        self.dst = base / "destination"
        (self.src / "ath11k/WCN6855/hw2.0").mkdir(parents=True)
        (self.src / "ath11k/WCN6855/hw2.0/amss.bin").write_text("Gaokun firmware")
        (self.src / "ath11k/WCN6855/hw2.1").symlink_to("hw2.0")
        (self.src / "qcom/sc8280xp").mkdir(parents=True)
        (self.src / "qcom/sc8280xp/dsp.mbn").write_text("Device DSP")
        self.dst.mkdir()

    def merge(self):
        subprocess.run(
            [
                "bash", "-euo", "pipefail", "-c",
                'source "$1"; merge_gaokun_firmware "$2" "$3"',
                "_", str(HELPER), str(self.src), str(self.dst),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_preserves_distribution_hw21_directory(self):
        existing = self.dst / "ath11k/WCN6855/hw2.1"
        existing.mkdir(parents=True)
        (existing / "board.bin").write_text("Distribution firmware")
        self.merge()
        self.assertTrue(existing.is_dir())
        self.assertFalse(existing.is_symlink())
        self.assertEqual((existing / "board.bin").read_text(), "Distribution firmware")
        self.assertEqual(
            (self.dst / "ath11k/WCN6855/hw2.0/amss.bin").read_text(),
            "Gaokun firmware",
        )
        self.assertEqual(
            (self.dst / "qcom/sc8280xp/dsp.mbn").read_text(),
            "Device DSP",
        )

    def test_creates_hw21_symlink_only_if_absent(self):
        self.merge()
        alias = self.dst / "ath11k/WCN6855/hw2.1"
        self.assertTrue(alias.is_symlink())
        self.assertEqual(alias.readlink(), pathlib.Path("hw2.0"))
        self.merge()  # Re-running must preserve the alias without error.
        self.assertTrue(alias.is_symlink())


if __name__ == "__main__":
    unittest.main()
