#!/usr/bin/python3

from hashlib import sha256
from io import BytesIO
from os import getenv, listdir, chmod, _exit, sep
from os.path import basename, dirname, join, normpath
from pathlib import Path
from stat import S_IEXEC
from sys import exit as sys_exit, path as sys_path
from threading import Lock
from uuid import uuid4
from glob import glob
from json import loads
from shutil import copytree, rmtree
from tarfile import open as tar_open
from traceback import format_exc
from zipfile import ZipFile

for deps_path in [
    join(sep, "usr", "share", "bunkerweb", *paths)
    for paths in (
        ("deps", "python"),
        ("utils",),
        ("api",),
        ("db",),
    )
]:
    if deps_path not in sys_path:
        sys_path.append(deps_path)

from magic import Magic
from requests import get

from Database import Database  # type: ignore
from logger import setup_logger  # type: ignore


logger = setup_logger("Jobs.download-plugins", getenv("LOG_LEVEL", "INFO"))
status = 0


def install_plugin(plugin_dir) -> bool:
    # Load plugin.json
    metadata = loads(Path(plugin_dir, "plugin.json").read_text(encoding="utf-8"))
    # Don't go further if plugin is already installed
    if Path("etc", "bunkerweb", "plugins", metadata["id"], "plugin.json").is_file():
        logger.warning(
            f"Skipping installation of plugin {metadata['id']} (already installed)",
        )
        return False
    # Copy the plugin
    copytree(plugin_dir, join(sep, "etc", "bunkerweb", "plugins", metadata["id"]))
    # Add u+x permissions to jobs files
    for job_file in glob(join(plugin_dir, "jobs", "*")):
        st = Path(job_file).stat()
        chmod(job_file, st.st_mode | S_IEXEC)
    logger.info(f"Plugin {metadata['id']} installed")
    return True


try:
    # Check if we have plugins to download
    plugin_urls = getenv("EXTERNAL_PLUGIN_URLS")
    if not plugin_urls:
        logger.info("No external plugins to download")
        _exit(0)

    plugin_nbr = 0

    # Loop on URLs
    logger.info(f"Downloading external plugins from {plugin_urls}...")
    for plugin_url in plugin_urls.split(" "):
        # Download Plugin file
        try:
            if plugin_urls.startswith("file://"):
                content = Path(normpath(plugin_urls[7:])).read_bytes()
            else:
                content = b""
                resp = get(
                    plugin_url,
                    headers={"User-Agent": "BunkerWeb"},
                    stream=True,
                    timeout=30,
                )

                if resp.status_code != 200:
                    logger.warning(f"Got status code {resp.status_code}, skipping...")
                    continue

                # Iterate over the response content in chunks
                for chunk in resp.iter_content(chunk_size=8192):
                    if chunk:
                        content += chunk
        except:
            logger.error(
                f"Exception while downloading plugin(s) from {plugin_url} :\n{format_exc()}",
            )
            status = 2
            continue

        # Extract it to tmp folder
        temp_dir = join(sep, "var", "tmp", "bunkerweb", "plugins", str(uuid4()))
        try:
            Path(temp_dir).mkdir(parents=True, exist_ok=True)
            file_type = Magic(mime=True).from_buffer(content)

            if file_type == "application/zip":
                with ZipFile(BytesIO(content)) as zf:
                    zf.extractall(path=temp_dir)
            elif file_type == "application/gzip":
                with tar_open(fileobj=BytesIO(content), mode="r:gz") as tar:
                    tar.extractall(path=temp_dir)
            elif file_type == "application/x-tar":
                with tar_open(fileobj=BytesIO(content), mode="r") as tar:
                    tar.extractall(path=temp_dir)
            else:
                logger.error(f"Unknown file type for {plugin_url}, either zip or tar are supported, skipping...")
                continue
        except:
            logger.error(
                f"Exception while decompressing plugin(s) from {plugin_url} :\n{format_exc()}",
            )
            status = 2
            continue

        # Install plugins
        try:
            for plugin_dir in glob(join(temp_dir, "**", "plugin.json"), recursive=True):
                try:
                    if install_plugin(dirname(plugin_dir)):
                        plugin_nbr += 1
                except FileExistsError:
                    logger.warning(
                        f"Skipping installation of plugin {basename(dirname(plugin_dir))} (already installed)",
                    )
        except:
            logger.error(
                f"Exception while installing plugin(s) from {plugin_url} :\n{format_exc()}",
            )
            status = 2

    if not plugin_nbr:
        logger.info("No external plugins to update to database")
        _exit(0)

    external_plugins = []
    external_plugins_ids = []
    plugins_dir = join(sep, "etc", "bunkerweb", "plugins")
    for plugin in listdir(plugins_dir):
        path = join(plugins_dir, plugin)
        if not Path(path, "plugin.json").is_file():
            logger.warning(f"Plugin {plugin} is not valid, deleting it...")
            rmtree(path, ignore_errors=True)
            continue

        plugin_file = loads(Path(path, "plugin.json").read_text(encoding="utf-8"))

        plugin_content = BytesIO()
        with tar_open(fileobj=plugin_content, mode="w:gz", compresslevel=9) as tar:
            tar.add(path, arcname=basename(path))
        plugin_content.seek(0)
        value = plugin_content.getvalue()

        plugin_file.update(
            {
                "external": True,
                "page": False,
                "method": "scheduler",
                "data": value,
                "checksum": sha256(value).hexdigest(),
            }
        )

        if "ui" in listdir(path):
            plugin_file["page"] = True

        external_plugins.append(plugin_file)
        external_plugins_ids.append(plugin_file["id"])

    db = Database(logger, sqlalchemy_string=getenv("DATABASE_URI"), pool=False)
    lock = Lock()

    for plugin in db.get_plugins(external=True, with_data=True):
        if plugin["method"] != "scheduler" and plugin["id"] not in external_plugins_ids:
            external_plugins.append(plugin)

    with lock:
        err = db.update_external_plugins(external_plugins)

    if err:
        logger.error(
            f"Couldn't update external plugins to database: {err}",
        )

    status = 1
    logger.info("External plugins downloaded and installed")

except:
    status = 2
    logger.error(f"Exception while running download-plugins.py :\n{format_exc()}")

for plugin_tmp in glob(join(sep, "var", "tmp", "bunkerweb", "plugins-*")):
    rmtree(plugin_tmp, ignore_errors=True)

sys_exit(status)
