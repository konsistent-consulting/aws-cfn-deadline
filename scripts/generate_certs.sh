#!/bin/bash
set -euo pipefail

# ===== Global settings =====
BASE_DIR="$(pwd)/deadline10"

# DNS name for the Load Balancer (CN + SAN)
LB_DNS="deadline-eu-west-2.konsistent.dev"

# Password for exporting PFX bundles
#PFX_PASS="ChangeMe123!"
#Region to use for ACM and SSM
REGION="eu-west-2"

create_ca() {
  local CA_DIR="$BASE_DIR/certs"
  mkdir -p "$CA_DIR"

  if [[ -f "$CA_DIR/ca.key" || -f "$CA_DIR/ca.crt" ]]; then
    echo "❌ CA already exists in $CA_DIR (ca.key/ca.crt found). Aborting."
    exit 1
  fi

  echo "🔑 Generating CA private key..."
  openssl genpkey -algorithm RSA -out "$CA_DIR/ca.key"

  echo "📜 Generating self-signed CA certificate (CN=CA, 10 years)..."
  openssl req -new -x509 \
    -key "$CA_DIR/ca.key" \
    -out "$CA_DIR/ca.crt" \
    -days 3650 \
    -subj "/CN=CA"

  echo "⚙️  Creating usage.cnf..."
  cat > "$CA_DIR/usage.cnf" <<'EOF'
[serverAuth]
extendedKeyUsage = serverAuth

[clientAuth]
extendedKeyUsage = clientAuth
EOF

  echo "✅ CA setup complete. Files created in $CA_DIR:"
  ls -lh "$CA_DIR"/ca.* "$CA_DIR"/usage.cnf | awk '{print "   📂 " $9 " (" $5 ")"}'
}

create_server_cert() {
  local CA_DIR="$BASE_DIR/certs"
  local SRV_DIR="$BASE_DIR/server"
  mkdir -p "$SRV_DIR"

  if [[ ! -f "$CA_DIR/ca.key" || ! -f "$CA_DIR/ca.crt" ]]; then
    echo "❌ CA not found at $CA_DIR. Run create_ca first."
    exit 1
  fi

  if [[ -f "$SRV_DIR/server.key" || -f "$SRV_DIR/server.crt" || -f "$SRV_DIR/server.pfx" ]]; then
    echo "❌ Server cert already exists in $SRV_DIR. Aborting."
    exit 1
  fi

  echo "🔑 Generating server key + CSR (CN=${LB_DNS})..."
  openssl req -new -nodes -newkey rsa:4096 \
    -keyout "$SRV_DIR/server.key" \
    -out "$SRV_DIR/server.req.pem" \
    -subj "/CN=${LB_DNS}"

  echo "✍️  Signing server certificate with CA (10 year)..."
  openssl x509 -req -days 3650 \
    -in "$SRV_DIR/server.req.pem" \
    -out "$SRV_DIR/server.crt" \
    -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -extfile "$CA_DIR/usage.cnf" -extensions serverAuth

  echo "📦 Exporting PFX bundle (non-password protected)..."
  openssl pkcs12 -export \
    -in "$SRV_DIR/server.crt" \
    -inkey "$SRV_DIR/server.key" \
    -certfile "$CA_DIR/ca.crt" \
    -out "$SRV_DIR/server.pfx" \
    -passout pass:

  echo "✅ Server certificate created in $SRV_DIR:"
  ls -lh "$SRV_DIR"/server.* | awk '{print "   📂 " $9 " (" $5 ")"}'
  echo "ℹ️  CA remains in: $CA_DIR (not copied to server dir)"
}

# create_client_cert <client_name>
create_client_cert() {
  local CLIENT_NAME="Deadline10RemoteClient"
  local CA_DIR="$BASE_DIR/certs"
  local CLI_DIR="$BASE_DIR/client"
  mkdir -p "$CLI_DIR"

  # Ensure CA exists
  if [[ ! -f "$CA_DIR/ca.key" || ! -f "$CA_DIR/ca.crt" ]]; then
    echo "❌ CA not found at $CA_DIR. Run create_ca first."
    exit 1
  fi

  # Prevent overwriting existing certs
  if [[ -f "$CLI_DIR/$CLIENT_NAME.key" || -f "$CLI_DIR/$CLIENT_NAME.crt" || -f "$CLI_DIR/$CLIENT_NAME.pfx" ]]; then
    echo "❌ Client cert already exists in $CLI_DIR. Aborting."
    exit 1
  fi

  echo "🔑 Generating client key + CSR (CN=${CLIENT_NAME})..."
  openssl req -new -nodes -newkey rsa:4096 \
    -keyout "$CLI_DIR/$CLIENT_NAME.key" \
    -out "$CLI_DIR/$CLIENT_NAME.req.pem" \
    -subj "/CN=${CLIENT_NAME}"

  echo "✍️  Signing client certificate with CA (${CLIENT_DAYS:-365} days, EKU=clientAuth)..."
  openssl x509 -req -days "${CLIENT_DAYS:-365}" \
    -in "$CLI_DIR/$CLIENT_NAME.req.pem" \
    -out "$CLI_DIR/$CLIENT_NAME.crt" \
    -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -CAcreateserial \
    -extfile "$CA_DIR/usage.cnf" -extensions clientAuth

  echo "📦 Exporting CLIENT PFX bundle ($([[ -n "${CLIENT_PFX_PASS:-}" ]] && echo 'password protected' || echo 'no password'))..."
  if [[ -n "${CLIENT_PFX_PASS:-}" ]]; then
    openssl pkcs12 -export \
      -in "$CLI_DIR/$CLIENT_NAME.crt" \
      -inkey "$CLI_DIR/$CLIENT_NAME.key" \
      -certfile "$CA_DIR/ca.crt" \
      -out "$CLI_DIR/$CLIENT_NAME.pfx" \
      -passout pass:
  else
    openssl pkcs12 -export \
      -in "$CLI_DIR/$CLIENT_NAME.crt" \
      -inkey "$CLI_DIR/$CLIENT_NAME.key" \
      -certfile "$CA_DIR/ca.crt" \
      -out "$CLI_DIR/$CLIENT_NAME.pfx" \
      -passout pass:
  fi

  echo "✅ Client certificate created in $CLI_DIR:"
  ls -lh "$CLI_DIR"/$CLIENT_NAME.* | awk '{print "   📂 " $9 " (" $5 ")"}'
  echo "ℹ️  Distribute $CLIENT_NAME.pfx to all client machines (with password if set)."
}

import_server_cert_to_acm() {
  local CA_DIR="$BASE_DIR/certs"
  local SRV_DIR="$BASE_DIR/server"

  # Check files exist
  for f in "$SRV_DIR/server.crt" "$SRV_DIR/server.key" "$CA_DIR/ca.crt"; do
    if [[ ! -f "$f" ]]; then
      echo "❌ Required file missing: $f"
      exit 1
    fi
  done

  echo "🌐 Importing server certificate into ACM (profile=kc-dev-studio)..."

  # Import into ACM
  ACM_ARN=$(aws acm import-certificate \
    --certificate fileb://"$SRV_DIR/server.crt" \
    --private-key fileb://"$SRV_DIR/server.key" \
    --certificate-chain fileb://"$CA_DIR/ca.crt" \
    --query CertificateArn \
    --output text \
    --region $REGION \
    --profile kc-dev-studio)

  if [[ -z "$ACM_ARN" ]]; then
    echo "❌ Failed to import certificate to ACM"
    exit 1
  fi

  echo "✅ Certificate imported to ACM"
  echo "   ARN: $ACM_ARN"

  # Optional: store in SSM for use in CFN
  aws ssm put-parameter \
    --name "/managed-studio/studio-ldn-deadline/deadline10/server-cert-arn" \
    --type String \
    --value "$ACM_ARN" \
    --overwrite \
    --region $REGION \
    --profile kc-dev-studio >/dev/null

  echo "📦 Stored ARN in SSM: /managed-studio/studio-ldn-deadline/deadline10/server-cert-arn"
}

# ===== Dispatcher =====
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    ca) create_ca ;;
    server) create_server_cert ;;
    client) create_client_cert ;;
    import_cert) import_server_cert_to_acm ;;
    *)
      echo "Usage: $0 {ca|server|client}"
      exit 1
      ;;
  esac
fi