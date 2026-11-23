"""Files the addons share by copy must stay identical.   Usage: python dashboard/tests/test_addons_shared.py

Each addon has to work installed alone, so shared code (StatusWindow.lua, the /<addon> status window) ships as a
copy in every addon that uses it. A fix made in one copy has to reach all of them."""
import glob
import os
import unittest

ADDONS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "addons")
SHARED = ["StatusWindow.lua"]


class SharedFilesTest(unittest.TestCase):
    def test_copies_are_identical(self):
        for name in SHARED:
            copies = sorted(glob.glob(os.path.join(ADDONS, "*", name)))
            self.assertTrue(copies, "no addon has %s" % name)
            first = open(copies[0], "rb").read()
            for path in copies[1:]:
                with self.subTest(copy=os.path.relpath(path, ADDONS)):
                    self.assertEqual(open(path, "rb").read(), first,
                                     "%s differs from %s: copy the fixed file to every addon"
                                     % (os.path.relpath(path, ADDONS), os.path.relpath(copies[0], ADDONS)))

    def test_each_copy_is_in_its_toc(self):
        for name in SHARED:
            for path in glob.glob(os.path.join(ADDONS, "*", name)):
                addon = os.path.basename(os.path.dirname(path))
                with open(os.path.join(os.path.dirname(path), addon + ".toc"), encoding="utf-8") as fh:
                    lines = [line.strip() for line in fh]
                with self.subTest(addon=addon):
                    self.assertIn(name, lines, "%s ships %s but its .toc doesn't load it" % (addon, name))


if __name__ == "__main__":
    unittest.main()
