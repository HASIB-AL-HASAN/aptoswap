# Aptoswap

## Development

### Prepare

- Run `aptos init` in the workspace folder to generate the package address if there's no one. Make sure that 
the name is set to `default`. We recommand use default localhost development for the default account, which could
be generated as:

```shell
aptos init --profile default --rest-url http://localhost:8080 --faucet-url http://localhost:8081
```


### Publish Compile Package

- Enter the `develop` folder, run `npm install` to install the dependencies. Make sure you already build the dependency of aptos typescript sdk in `submodules`
- Run `npm run publish` to publish the new package.

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