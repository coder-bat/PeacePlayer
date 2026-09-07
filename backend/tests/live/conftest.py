import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).parent))


def pytest_collection_modifyitems(items):
    for item in items:
        if "live" in Path(item.path).parts:
            item.add_marker(pytest.mark.live)


@pytest.fixture(autouse=True)
def disposable_service_only():
    from live_support import require_disposable_service
    require_disposable_service()
