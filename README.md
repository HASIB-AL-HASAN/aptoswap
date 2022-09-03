# Aptoswap

## Development

### Publish Compile Package

- For local publish, run `APTOSWAP_PUBLISH_NETWORK="local" ./script/publish.sh"`
- For devnet publish, run `APTOSWAP_PUBLISH_NETWORK="devnet" ./script/publish.sh"`

### Cooperate with `swap-ui`:

- Copy the `package_info`'s `package` information into the `aptoswap` field in the `<swap-ui-packge>/ui/config/config.test.json`. The json file should look like:

```json
{
    "current": "aptos",
    "configs": {
        "sui": "..."
        "aptos": {
            "type": "aptos",
            "endpoint": "http://127.0.0.1:8080",
            "aptoswap": {
                "package": "<your-package-addreess>"
            }
        }
    }
}
```