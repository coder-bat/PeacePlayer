# YT Audio System - Makefile
# Quick commands for setup and development

.PHONY: help backend ios clean setup run

help:
	@echo "YT Audio System Commands:"
	@echo "  make setup    - Setup Python virtual environment"
	@echo "  make backend  - Start the Python backend server"
	@echo "  make ios      - Open iOS project in Xcode"
	@echo "  make auth     - Run OAuth authentication setup"
	@echo "  make clean    - Clean temporary files"
	@echo "  make install  - Install all dependencies"

# Setup Python environment
setup:
	cd backend && python3 -m venv venv
	cd backend && ./venv/bin/pip install -r requirements.txt
	@echo "Setup complete. Run 'make auth' to authenticate."

# Install dependencies
install: setup

# Run OAuth authentication
auth:
	cd backend && ./venv/bin/python setup_oauth.py

# Start backend server
backend:
	cd backend && ./venv/bin/python server.py

# Start backend with specific IP (for device testing)
backend-device:
	@echo "Starting server on all interfaces..."
	cd backend && HOST=0.0.0.0 ./venv/bin/python server.py

# Open iOS folder (create project if needed)
ios:
	@if [ -f "ios/YTAudioPlayer.xcodeproj/project.pbxproj" ]; then \
		open ios/YTAudioPlayer.xcodeproj; \
	else \
		echo ""; \
		echo "⚠️  Xcode project not found!"; \
		echo ""; \
		echo "To create the iOS project:"; \
		echo "1. Open Xcode"; \
		echo "2. File → New → Project"; \
		echo "3. Select iOS → App template"; \
		echo "4. Name: YTAudioPlayer"; \
		echo "5. Save to: $(PWD)/ios/"; \
		echo ""; \
		echo "Then replace the auto-generated files with our source files."; \
		echo "See ios/QUICK_START.md for detailed instructions."; \
		echo ""; \
		open ios/; \
	fi

# Clean temporary files
clean:
	find backend -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find backend -type f -name "*.pyc" -delete 2>/dev/null || true
	find backend -type f -name "*.pyo" -delete 2>/dev/null || true
	rm -rf backend/.temp_*.webm 2>/dev/null || true
	@echo "Cleaned temporary files"

# Deep clean (includes virtual environment)
distclean: clean
	rm -rf backend/venv
	rm -f backend/oauth.json
	@echo "Deep clean complete. Run 'make setup' to reconfigure."

# Check system requirements
check:
	@echo "Checking requirements..."
	@which python3 || (echo "❌ Python 3 not found" && exit 1)
	@echo "✅ Python 3 found"
	@which xcodebuild || (echo "⚠️  Xcode command line tools not found")
	@echo "✅ Checks complete"

# Development mode (backend with auto-reload)
dev:
	cd backend && ./venv/bin/uvicorn server:app --reload --host 0.0.0.0 --port 8181

# Show local IP (for iOS configuration)
ip:
	@echo "Your local IP addresses:"
	@ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $$2}'
	@echo ""
	@echo "Update ios/YTAudioPlayer/Sources/APIService.swift with your IP"
