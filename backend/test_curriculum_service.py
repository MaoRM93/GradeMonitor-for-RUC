import os
import tempfile
import unittest

os.environ["GRADEMONITOR_DATA_DIR"] = tempfile.mkdtemp(prefix="gm-curriculum-test-")

from backend.service import curriculum_service
from backend.storage.settings import save_settings


class CurriculumServiceTest(unittest.TestCase):
    def setUp(self):
        save_settings({"username": "2024123456"})

    def test_decrypts_matching_grade_pdf(self):
        data = curriculum_service._decrypt("2024")
        self.assertTrue(data.startswith(b"%PDF-"))

    def test_rejects_one_time_link_after_account_grade_changes(self):
        opened = []
        original_open = curriculum_service.webbrowser.open
        curriculum_service.webbrowser.open = opened.append
        try:
            curriculum_service.open_curriculum()
        finally:
            curriculum_service.webbrowser.open = original_open
        token = next(iter(curriculum_service._OPEN_TOKENS))
        save_settings({"username": "2025123456"})
        with self.assertRaises(Exception) as error:
            curriculum_service.view_curriculum("2024", token)
        self.assertEqual(getattr(error.exception, "status_code", None), 403)


if __name__ == "__main__":
    unittest.main()
