#!/usr/bin/env python3
"""Moved to tests/sessions/matrix.py; this path keeps working for the tools that call it."""
import os, sys
os.execv(sys.executable, [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sessions', 'matrix.py'), *sys.argv[1:]])
