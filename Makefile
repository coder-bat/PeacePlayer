# Python 3.11 is the supported backend runtime. Override VENV for isolated setup.
PYTHON ?= python3.11
VENV ?= backend/.venv
BACKEND_PYTHON = $(abspath $(VENV))/bin/python

.PHONY: help setup setup-dev install backend backend-device dev auth test check ios clean
help:
	@echo "make setup | setup-dev | backend | test | check | ios"

setup:
	$(PYTHON) -c 'import sys; assert sys.version_info[:2] == (3, 11), "Python 3.11 required"'
	$(PYTHON) -m venv "$(VENV)"
	"$(BACKEND_PYTHON)" -m pip install -r backend/requirements.txt
	"$(BACKEND_PYTHON)" -m pip check

setup-dev: setup
	"$(BACKEND_PYTHON)" -m pip install -r backend/requirements-dev.txt

install: setup

backend:
	cd backend && "$(BACKEND_PYTHON)" preflight.py
	cd backend && "$(BACKEND_PYTHON)" server.py

backend-device:
	$(MAKE) backend HOST=0.0.0.0

# YouTube account access is separate from mandatory Apple sign-in in the app.
auth:
	cd backend && "$(BACKEND_PYTHON)" setup_oauth.py

dev:
	cd backend && "$(BACKEND_PYTHON)" -m uvicorn server:app --reload --host 0.0.0.0 --port 8181

test:
	cd backend && "$(BACKEND_PYTHON)" -m pytest

check:
	"$(BACKEND_PYTHON)" -m pip check
	cd backend && "$(BACKEND_PYTHON)" preflight.py

ios:
	open ios/YTAudioPlayer.xcodeproj

clean:
	"$(PYTHON)" -c 'from pathlib import Path; [p.unlink() for p in Path("backend").glob("*.pyc")]'
