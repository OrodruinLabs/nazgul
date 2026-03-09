# Tool Pre-flight Detection Commands

Map the chosen stack to required CLI tools and check each using these commands.

## Tool Detection Table

| Tool | Check Command | Install (macOS) | Install (Linux) |
|------|--------------|-----------------|-----------------|
| node | `node --version` | `brew install node` | `curl -fsSL https://deb.nodesource.com/setup_22.x \| sudo bash - && sudo apt install -y nodejs` |
| pnpm | `pnpm --version` | `npm install -g pnpm` | `npm install -g pnpm` |
| npm | `npm --version` | (comes with node) | (comes with node) |
| bun | `bun --version` | `brew install oven-sh/bun/bun` | `curl -fsSL https://bun.sh/install \| bash` |
| yarn | `yarn --version` | `npm install -g yarn` | `npm install -g yarn` |
| python3 | `python3 --version` | `brew install python` | `sudo apt install -y python3` |
| uv | `uv --version` | `brew install uv` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| pip | `pip3 --version` | (comes with python) | (comes with python) |
| go | `go version` | `brew install go` | `sudo apt install -y golang` |
| rust/cargo | `cargo --version` | `brew install rust` | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| ruby | `ruby --version` | `brew install ruby` | `sudo apt install -y ruby` |
| dotnet | `dotnet --version` | `brew install dotnet` | `sudo apt install -y dotnet-sdk-9.0` |
| nuget | `nuget help 2>&1 \| head -1` or `dotnet nuget --version` | (comes with dotnet SDK) | (comes with dotnet SDK) |
| docker | `docker --version` | `brew install --cask docker` | `sudo apt install -y docker.io` |
| postgresql | `pg_isready` or `psql --version` | `brew install postgresql@16 && brew services start postgresql@16` | `sudo apt install -y postgresql` |
| sqlite3 | `sqlite3 --version` | `brew install sqlite` | `sudo apt install -y sqlite3` |
| gh | `gh --version` | `brew install gh` | `sudo apt install -y gh` |
| jq | `jq --version` | `brew install jq` | `sudo apt install -y jq` |
| terraform | `terraform --version` | `brew install terraform` | `sudo apt install -y terraform` |
| kubectl | `kubectl version --client` | `brew install kubectl` | `sudo apt install -y kubectl` |
| helm | `helm version` | `brew install helm` | `sudo apt install -y helm` |
| aws-cli | `aws --version` | `brew install awscli` | `sudo apt install -y awscli` |
| gcloud | `gcloud --version` | `brew install --cask google-cloud-sdk` | `curl https://sdk.cloud.google.com \| bash` |
| az | `az --version` | `brew install azure-cli` | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` |
