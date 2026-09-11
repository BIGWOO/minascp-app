#!/usr/bin/env python3
"""Verify generated release metadata and all signatures with Sparkle's own tool."""
import pathlib
import subprocess
import sys
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(path, build, prefix, tools, account):
    path = pathlib.Path(path)
    raw = path.read_text()
    ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    items = ET.fromstring(raw).findall('./channel/item')
    require(len(items) == 1, 'Expected one complete release')
    item = items[0]
    enclosure = item.find('enclosure')
    require(item.findtext(ns + 'version') == build, 'Wrong build number')
    require(enclosure is not None, 'Missing archive')
    require(enclosure.get('url', '').endswith('.zip'), 'Update must use ZIP')
    notes = item.find(ns + 'releaseNotesLink')
    require(notes is not None, 'Missing release notes')
    require('<!-- sparkle-signatures:\nedSignature: ' in raw, 'Missing feed signature')
    command = [str(pathlib.Path(tools) / 'sign_update'), '--account', account, '--verify']
    subprocess.run(command + [str(path)], check=True)
    for element, url in [(enclosure, enclosure.get('url', '')), (notes, notes.text or '')]:
        require(url.startswith(prefix), 'Asset URL must use the fixed release prefix')
        filename = unquote(urlparse(url).path.rsplit('/', 1)[-1])
        require(filename and '/' not in filename and filename not in ('.', '..'), 'Invalid asset filename')
        asset = path.parent / filename
        signature = element.get(ns + 'edSignature')
        require(signature, 'Missing asset signature')
        length = int(element.get('length') or element.get(ns + 'length') or '0')
        require(length > 0 and asset.stat().st_size == length, 'Asset length mismatch')
        subprocess.run(command + [str(asset), signature], check=True)
    print('Appcast, ZIP and release notes verified')


if __name__ == '__main__':
    try:
        verify(*sys.argv[1:])
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
