import argparse
import importlib.util
import shutil
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("factory_config", ROOT / "scripts/factory.py")
factory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(factory)


@pytest.fixture
def configuration():
    return yaml.safe_load((ROOT / "config/default.yml").read_text())


def test_valid_configuration_is_accepted_by_real_schema(configuration):
    assert factory.validate_config(configuration) is configuration


@pytest.mark.parametrize(
    "workspace", ["/home/other/Dev", "/home/coder/../other/Dev", "/home/coder"]
)
def test_workspace_cannot_escape_operator_home(configuration, workspace):
    configuration["factory"]["workspace"] = workspace
    with pytest.raises(ValueError, match="workspace"):
        factory.validate_config(configuration)


def test_invalid_secret_field_is_rejected_without_echoing_value(configuration):
    private_value = "PRIVATE_VALUE_MUST_NOT_APPEAR_IN_DIAGNOSTICS"
    configuration["factory"]["api_key"] = private_value
    with pytest.raises(ValueError) as failure:
        factory.validate_config(configuration)
    assert private_value not in str(failure.value)


def test_firstmate_cannot_silently_omit_its_agent_dependencies(configuration):
    configuration["factory"]["profiles"]["agents"] = False
    with pytest.raises(ValueError, match="Firstmate requires"):
        factory.validate_config(configuration)


def test_bad_polling_window_cannot_disable_idle_accrual(configuration):
    configuration["factory"]["browser_prune"]["max_gap_seconds"] = 120
    with pytest.raises(ValueError, match="observation intervals"):
        factory.validate_config(configuration)


def test_init_preserves_existing_local_configuration(tmp_path, monkeypatch):
    for path in ("config", "schemas"):
        shutil.copytree(ROOT / path, tmp_path / path)
    shutil.copyfile(ROOT / "toolchain.lock.json", tmp_path / "toolchain.lock.json")
    monkeypatch.setattr(factory, "ROOT", tmp_path)
    args = argparse.Namespace(user="coder", home="/home/coder", container=True)
    factory.initialize(args)
    local = tmp_path / ".local/host.yml"
    first = local.read_bytes()
    config = factory.load_config(local)["factory"]
    assert not config["start_services"] and not config["profiles"]["docker"]
    assert config["profiles"]["agents"]
    with pytest.raises(FileExistsError):
        factory.initialize(args)
    assert local.read_bytes() == first


def test_root_operator_is_rejected_before_config_is_written(tmp_path, monkeypatch):
    for path in ("config", "schemas"):
        shutil.copytree(ROOT / path, tmp_path / path)
    shutil.copyfile(ROOT / "toolchain.lock.json", tmp_path / "toolchain.lock.json")
    monkeypatch.setattr(factory, "ROOT", tmp_path)
    with pytest.raises(ValueError, match="non-root"):
        factory.initialize(argparse.Namespace(user="root", home="/home/root", container=False))
    assert not (tmp_path / ".local/host.yml").exists()
