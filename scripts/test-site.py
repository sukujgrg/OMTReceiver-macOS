#!/usr/bin/env python3
"""Check the static site's download links, local assets, and navigation offline."""

from html.parser import HTMLParser
from pathlib import Path
import unittest
from urllib.parse import unquote, urlsplit

SITE = Path(__file__).resolve().parents[1] / "site"
LATEST = "https://github.com/sukujgrg/OMTReceiver-macOS/releases/latest"


class Document(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.elements = []
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))


class SiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = Document((SITE / "index.html").read_text(encoding="utf-8"))

    def test_download_buttons_always_open_latest_release(self):
        buttons = [attrs for tag, attrs in self.document.elements if tag == "a" and "button-primary" in attrs.get("class", "").split()]
        self.assertGreaterEqual(len(buttons), 1, "The page must offer a download")
        for button in buttons:
            self.assertEqual(button.get("href"), LATEST)
        for tag, attrs in self.document.elements:
            if tag == "a":
                href = attrs.get("href", "")
                self.assertNotIn("/releases/download/", href, "Use GitHub's latest release page rather than a fixed archive")
                self.assertNotIn("/releases/tag/", href, "Use GitHub's latest release page rather than a fixed tag")

    def test_local_resources_exist_under_project_relative_paths(self):
        for tag, attrs in self.document.elements:
            value = attrs.get("src")
            if tag == "link" and attrs.get("rel") in ("stylesheet", "icon"):
                value = attrs.get("href")
            if value is None:
                continue
            with self.subTest(resource=value):
                parts = urlsplit(value)
                self.assertFalse(parts.scheme or parts.netloc, "Site resources should remain self-contained")
                self.assertFalse(parts.path.startswith("/"), "Root paths break GitHub project Pages")
                resource = (SITE / unquote(parts.path)).resolve()
                self.assertTrue(resource.is_relative_to(SITE), "Resource must remain inside site/")
                self.assertTrue(resource.is_file(), f"Missing site resource: {value}")

    def test_navigation_anchors_resolve_and_external_links_use_https(self):
        identifiers = {attrs["id"] for _, attrs in self.document.elements if "id" in attrs}
        for tag, attrs in self.document.elements:
            if tag != "a":
                continue
            href = attrs.get("href", "")
            with self.subTest(href=href):
                self.assertTrue(href, "Links must have a destination")
                if href.startswith("#"):
                    if href != "#":
                        self.assertIn(href[1:], identifiers)
                else:
                    self.assertEqual(urlsplit(href).scheme, "https")

    def test_document_has_basic_accessibility_and_mobile_metadata(self):
        elements = self.document.elements
        self.assertTrue(any(tag == "html" and attrs.get("lang") == "en" for tag, attrs in elements))
        self.assertTrue(any(tag == "meta" and attrs.get("name") == "viewport" for tag, attrs in elements))
        self.assertEqual(sum(tag == "h1" for tag, _ in elements), 1)
        self.assertTrue(any(tag == "main" and attrs.get("id") == "main" for tag, attrs in elements))
        self.assertTrue(any(tag == "a" and attrs.get("href") == "#main" for tag, attrs in elements))
        for tag, attrs in elements:
            if tag == "img":
                self.assertIn("alt", attrs, "Decorative images need an empty alt; content images need descriptive alt")


if __name__ == "__main__":
    unittest.main()
