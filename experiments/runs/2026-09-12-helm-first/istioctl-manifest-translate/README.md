# IstioOperator to Helm Migration

This folder contains auto-generated output from the `istioctl manifest translate` command.
Note the `manifest translate` command only outputs this folders contents, and does not modify the cluster state.

Follow the instructions below for each component to complete the migration.

# Components
* ✅ **Component `base`**: migration is supported!

  The translated values have been written to base-values.yaml.
  You may use these directly, or follow the guided `install-base.sh` script.
* ✅ **Component `pilot`**: migration is supported!

  The translated values have been written to pilot-values.yaml.
  You may use these directly, or follow the guided `install-pilot.sh` script.
* ❌ **Component `istio-ingressgateway`**: migration is **NOT** directly supported!
