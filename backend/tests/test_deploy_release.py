"""Exercise release switching/rollback against fake directories, never launchd."""
import importlib.util
from pathlib import Path
import pytest

spec = importlib.util.spec_from_file_location("deploy_release", Path(__file__).resolve().parents[2] / "scripts/deploy-release.py")
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


def test_failed_release_restores_previous_code_and_preserves_data(tmp_path):
    old = tmp_path / "releases/old"
    new = tmp_path / "releases/new"
    old.mkdir(parents=True)
    new.mkdir()
    deploy.switch_link(tmp_path / "current", old)
    data = tmp_path / "shared/snapshot.json"
    data.parent.mkdir()
    data.write_text('newer user data')
    checked = []
    restarted = []
    def probe(revision):
        checked.append(revision)
        if revision == "new":
            raise RuntimeError("candidate unhealthy")
    with pytest.raises(RuntimeError, match="candidate unhealthy"):
        deploy.activate(tmp_path, new, lambda: restarted.append(True), probe)
    assert (tmp_path / "current").resolve() == old
    assert checked == ["new", "old"]
    assert len(restarted) == 2
    assert data.read_text() == 'newer user data'


def test_success_records_previous_release(tmp_path):
    old, new = tmp_path / "old", tmp_path / "new"
    old.mkdir()
    new.mkdir()
    deploy.switch_link(tmp_path / "current", old)
    deploy.activate(tmp_path, new, lambda: None, lambda _: None)
    assert (tmp_path / "current").resolve() == new
    assert (tmp_path / "previous").resolve() == old
