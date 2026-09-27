#!/usr/bin/env python3
"""Prepare the native package cache before Flutter resolves dependencies."""
from pathlib import Path
import subprocess
import sys

APP = Path(__file__).resolve().parents[1]


def prepare_flutter_project(flutter_project):
    if sys.platform == 'darwin':
        # Flutter copies SwiftPM plugins using rsync before Xcode initializes its
        # package cache. Older macOS rsync versions do not create missing parents.
        (flutter_project / 'build/macos/SourcePackages').mkdir(parents=True, exist_ok=True)


def main():
    flutter_project = APP / 'flutter_app'
    prepare_flutter_project(flutter_project)
    subprocess.run(['flutter', 'pub', 'get'], cwd=flutter_project, check=True)


if __name__ == '__main__':
    main()
