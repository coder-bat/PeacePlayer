"""Validate the selected runtime and private configuration without network access."""
import argparse
import json
from runtime_config import settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--without-media-tools", action="store_true", help="Only for offline test environments")
    args = parser.parse_args()
    settings.validate(media_tools=not args.without_media_tools)
    # Auth import validates strength of the supplied secret; never display it.
    import apple_auth  # noqa: F401
    import server  # noqa: F401
    print(json.dumps({"status": "ready", "python": "3.11", "mediaToolsChecked": not args.without_media_tools}))


if __name__ == "__main__":
    main()
