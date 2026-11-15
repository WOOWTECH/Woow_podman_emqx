#!/usr/bin/env python3
"""Render optional HA discovery access for exactly one validated MQTT account."""
import argparse
from pathlib import Path
import re


def render(source, username):
    if not username:
        return source
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', username):
        raise ValueError('HA discovery username must be a literal MQTT account, not a pattern')
    return ('%% Explicit Home Assistant discovery account; other users keep their isolation.\n'
            f'{{allow, {{username, "{username}"}}, all, ["homeassistant/#"]}}.\n' + source)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--ha-user', default='')
    a = p.parse_args()
    result = render(a.source.read_text(), a.ha_user)
    a.output.write_text(result)
