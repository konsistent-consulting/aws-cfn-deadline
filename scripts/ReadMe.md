# Deadline 10 Certificate Management Script

This Bash script automates the creation and management of certificates for a **Deadline 10** deployment with a secure Application Load Balancer (ALB) in AWS.  
It provides helpers for generating a **Certificate Authority (CA)**, issuing **server and client certificates**, and importing the server certificate into **AWS Certificate Manager (ACM)** for use with the ALB.

---

## 📋 Features

- Generate a private **Certificate Authority (CA)**  
- Issue and sign **server certificates** for the Deadline ALB  
- Issue and sign **client certificates** for Deadline Remote Clients  
- Export **PFX bundles** for server and client use  
- Import server certificate into **AWS Certificate Manager (ACM)**  
- Store the ACM certificate ARN into **AWS Systems Manager (SSM) Parameter Store**  

---

## 📂 Directory Structure

Certificates are created under a `deadline10` folder in the current working directory:

```
deadline10/
├── certs/    # CA files (ca.key, ca.crt, usage.cnf)
├── server/   # Server certs (server.key, server.crt, server.pfx)
└── client/   # Client certs (Deadline10RemoteClient.key/crt/pfx)
```

---

## ⚙️ Prerequisites

- **Bash** (Linux/macOS or WSL on Windows)
- **OpenSSL** installed
- **AWS CLI v2** installed and configured with:
  - Profile: `kc-dev-studio`
  - Region: `eu-west-2`

---

## 🚀 Usage

Run the script with one of the supported commands:

```bash
./cert-manager.sh {ca|server|client|import_cert}
```

### 1. Create the Certificate Authority (CA)

Generates the root CA key and certificate (valid for 10 years).

```bash
./cert-manager.sh ca
```

Output files:
- `deadline10/certs/ca.key`
- `deadline10/certs/ca.crt`
- `deadline10/certs/usage.cnf`

---

### 2. Create a Server Certificate

Generates a server certificate signed by the CA for the ALB DNS name:

```bash
./cert-manager.sh server
```

Default CN:
- `deadline-eu-west-2.konsistent.dev`

Output files:
- `deadline10/server/server.key`
- `deadline10/server/server.crt`
- `deadline10/server/server.pfx` (bundle, no password)

---

### 3. Create a Client Certificate

Generates a client certificate (default CN = `Deadline10RemoteClient`) signed by the CA.  
This certificate is intended for distribution to Deadline remote clients.

```bash
./cert-manager.sh client
```

Output files:
- `deadline10/client/Deadline10RemoteClient.key`
- `deadline10/client/Deadline10RemoteClient.crt`
- `deadline10/client/Deadline10RemoteClient.pfx`

ℹ️ The `.pfx` file is what you distribute to client machines.

---

### 4. Import Server Certificate into AWS ACM

Imports the server certificate and chain into **AWS Certificate Manager** using the configured AWS profile and region.  
It then stores the resulting ARN into **SSM Parameter Store** at:

```
/managed-studio/studio-ldn-deadline/deadline10/server-cert-arn
```

Run:

```bash
./cert-manager.sh import_cert
```

---

## 🛑 Safety Checks

- The script will **abort** if a certificate already exists (to avoid accidental overwrites).  
- CA must be created **before** generating server or client certificates.  
- Import requires server certs and CA cert to exist.

---

## 🔧 Customization

- **Change ALB DNS Name:**  
  Update the `LB_DNS` variable at the top of the script.  
- **Region/Profile:**  
  Adjust `REGION` and `--profile` as needed.  
- **Client Cert Validity:**  
  Override default 365-day validity using `CLIENT_DAYS`, e.g.:

  ```bash
  CLIENT_DAYS=730 ./cert-manager.sh client
  ```

---

## 📌 Example Workflow

```bash
# Step 1: Create the CA
./cert-manager.sh ca

# Step 2: Create a server certificate
./cert-manager.sh server

# Step 3: Create a client certificate
./cert-manager.sh client

# Step 4: Import server cert into AWS ACM + save ARN to SSM
./cert-manager.sh import_cert
```

---

## ✅ Outputs Summary

- **CA** → `ca.key`, `ca.crt`, `usage.cnf`
- **Server** → `server.key`, `server.crt`, `server.pfx`
- **Client** → `Deadline10RemoteClient.key`, `Deadline10RemoteClient.crt`, `Deadline10RemoteClient.pfx`
- **AWS** → ACM certificate + ARN stored in SSM
