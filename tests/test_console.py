import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'skills/ios-local-publish/scripts'))
from ios_publish.console import render


class ConsoleTests(unittest.TestCase):
  def metadata(self):
    return dict(name='App <Example>', bundle_id='com.example.app', version='1.0', build='49', size_bytes=1048576, expires_at='2099-01-01T00:00:00+00:00')

  def test_unknown_history_fields_are_hidden_and_text_is_escaped(self):
    page = render(self.metadata(), 'itms-services://?a=1&b=2').decode()
    self.assertIn('App &lt;Example&gt;', page)
    self.assertIn('th:nth-child(2),td:nth-child(2){display:none}', page)
    self.assertNotIn('Install requirements', page)
    self.assertIn('itms-services://?a=1&amp;b=2', page)

  def test_expired_current_build_has_no_primary_install(self):
    data = {**self.metadata(), 'expires_at': '2020-01-01T00:00:00+00:00'}
    page = render(data, 'itms-services://example').decode()
    self.assertIn('Signing expired', page)
    self.assertNotIn('class="install"', page)
