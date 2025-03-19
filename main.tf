
resource "random_string" "acr_suffix" {
  length  = 8
  numeric = true
  special = false
  upper   = false
}

resource "azurerm_container_registry" "this" {
  location            = var.location
  name                = coalesce(var.container_registry_name, "cr${random_string.acr_suffix.result}")
  resource_group_name = var.resource_group_name
  sku                 = "Premium"
  tags                = var.tags
}

resource "azurerm_role_assignment" "acr" {
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  skip_service_principal_aad_check = true
}

resource "azurerm_user_assigned_identity" "aks" {
  count = length(var.managed_identities.user_assigned_resource_ids) > 0 ? 0 : 1

  location            = var.location
  name                = coalesce(var.user_assigned_identity_name, "uami-aks")
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  location                          = var.location
  name                              = "aks-${var.name}"
  resource_group_name               = var.resource_group_name
  automatic_upgrade_channel         = "patch"
  azure_policy_enabled              = true
  dns_prefix                        = var.name
  kubernetes_version                = var.kubernetes_version
  local_account_disabled            = false
  node_os_upgrade_channel           = "NodeImage"
  oidc_issuer_enabled               = true
  private_cluster_enabled           = true
  role_based_access_control_enabled = true
  sku_tier                          = "Standard"
  tags                              = var.tags
  workload_identity_enabled         = true

  default_node_pool {
    name                    = "agentpool"
    vm_size                 = "Standard_D16ds_v5"
    auto_scaling_enabled    = true
    host_encryption_enabled = true
    max_count               = 5
    max_pods                = 110
    min_count               = 2
    orchestrator_version    = var.orchestrator_version
    os_sku                  = "Ubuntu"
    tags                    = merge(var.tags, var.agents_tags)
    vnet_subnet_id          = azurerm_subnet.aks.id
    zones                   = try([for zone in local.regions_by_name_or_display_name[var.location].zones : zone], null)

    upgrade_settings {
      max_surge = "10%"
    }
  }
  auto_scaler_profile {
    balance_similar_node_groups = true
  }
  dynamic "azure_active_directory_role_based_access_control" {
    for_each = var.rbac_aad_admin_group_object_ids != null || var.rbac_aad_azure_rbac_enabled != null || var.rbac_aad_tenant_id != null ? [1] : []

    content {
      admin_group_object_ids = var.rbac_aad_admin_group_object_ids
      azure_rbac_enabled     = var.rbac_aad_azure_rbac_enabled
      tenant_id              = var.rbac_aad_tenant_id
    }
  }
  ## Resources that only support UserAssigned
  identity {
    type         = "UserAssigned"
    identity_ids = length(var.user_assigned_managed_identity_resource_ids) > 0 ? var.user_assigned_managed_identity_resource_ids : azurerm_user_assigned_identity.aks[*].id
  }
  monitor_metrics {
    annotations_allowed = try(var.monitor_metrics.annotations_allowed, null)
    labels_allowed      = try(var.monitor_metrics.labels_allowed, null)
  }
  network_profile {
    network_plugin      = "azure"
    load_balancer_sku   = "standard"
    network_plugin_mode = "overlay"
    network_policy      = "calico"
    outbound_type       = "userDefinedRouting"
    pod_cidr            = var.pod_cidr
  }
  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  depends_on = [azurerm_subnet_route_table_association.this]

  lifecycle {
    ignore_changes = [
      kubernetes_version
    ]
  }
}

# The following terraform_data is used to trigger the update of the AKS cluster when the kubernetes_version changes
# This is necessary because the azurerm_kubernetes_cluster resource ignores changes to the kubernetes_version attribute
# because AKS patch versions are upgraded automatically by Azure
# The kubernetes_version_keeper and aks_cluster_post_create resources implement a mechanism to force the update
# when the minor kubernetes version changes in var.kubernetes_version

resource "terraform_data" "kubernetes_version_keeper" {
  triggers_replace = {
    version = var.kubernetes_version
  }
}

resource "azapi_update_resource" "aks_cluster_post_create" {
  type = "Microsoft.ContainerService/managedClusters@2024-02-01"
  body = {
    properties = {
      kubernetesVersion = var.kubernetes_version
    }
  }
  resource_id = azurerm_kubernetes_cluster.this.id

  lifecycle {
    ignore_changes       = all
    replace_triggered_by = [terraform_data.kubernetes_version_keeper.id]
  }
}

resource "azurerm_log_analytics_workspace" "this" {
  location            = var.location
  name                = "log-${var.name}-aks"
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  tags                = var.tags
}

resource "azurerm_log_analytics_workspace_table" "this" {
  for_each = toset(local.log_analytics_tables)

  name         = each.value
  workspace_id = azurerm_log_analytics_workspace.this.id
  plan         = "Basic"
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "amds-${var.name}-aks"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_destination_type = "Dedicated"
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id

  # Kubernetes API Server
  enabled_log {
    category = "kube-apiserver"
  }
  # Kubernetes Audit
  enabled_log {
    category = "kube-audit"
  }
  # Kubernetes Audit Admin Logs
  enabled_log {
    category = "kube-audit-admin"
  }
  # Kubernetes Controller Manager
  enabled_log {
    category = "kube-controller-manager"
  }
  # Kubernetes Scheduler
  enabled_log {
    category = "kube-scheduler"
  }
  #Kubernetes Cluster Autoscaler
  enabled_log {
    category = "cluster-autoscaler"
  }
  #Kubernetes Cloud Controller Manager
  enabled_log {
    category = "cloud-controller-manager"
  }
  #guard
  enabled_log {
    category = "guard"
  }
  #csi-azuredisk-controller
  enabled_log {
    category = "csi-azuredisk-controller"
  }
  #csi-azurefile-controller
  enabled_log {
    category = "csi-azurefile-controller"
  }
  #csi-snapshot-controller
  enabled_log {
    category = "csi-snapshot-controller"
  }
  metric {
    category = "AllMetrics"
  }
}

# required AVM resources interfaces
resource "azurerm_management_lock" "this" {
  count = var.lock != null ? 1 : 0

  lock_level = var.lock.kind
  name       = coalesce(var.lock.name, "lock-${var.lock.kind}")
  scope      = azurerm_kubernetes_cluster.this.id
  notes      = var.lock.kind == "CanNotDelete" ? "Cannot delete the resource or its child resources." : "Cannot delete or modify the resource or its child resources."
}


resource "azurerm_kubernetes_cluster_node_pool" "this" {
  for_each = tomap({
    for pool in local.node_pools : pool.name => pool
  })

  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  name                  = each.value.name
  vm_size               = each.value.vm_size
  auto_scaling_enabled  = true
  max_count             = each.value.max_count
  min_count             = each.value.min_count
  orchestrator_version  = each.value.orchestrator_version
  os_sku                = each.value.os_sku
  tags                  = var.tags
  vnet_subnet_id        = azurerm_subnet.aks.id
  zones                 = each.value.zone == "" ? null : [each.value.zone]

  depends_on = [azapi_update_resource.aks_cluster_post_create]

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z][a-z0-9]{0,11}$", each.value.name))
      error_message = "The name must begin with a lowercase letter, contain only lowercase letters and numbers, and be between 1 and 12 characters in length."
    }
  }
}

# These resources allow the use of consistent local data files, and semver versioning
data "local_file" "compute_provider" {
  filename = "${path.module}/data/microsoft.compute_resourceTypes.json"
}

data "local_file" "locations" {
  filename = "${path.module}/data/locations.json"
}

resource "azurerm_virtual_network" "this" {
  address_space       = [var.virtual_network_address_space]
  location            = var.location
  name                = "vnet-${random_string.acr_suffix.result}"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  address_prefixes     = [var.node_cidr]
  name                 = "aks-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
}

resource "azurerm_subnet" "firewall" {
  address_prefixes     = [var.firewall_cidr]
  name                 = "AzureFirewallSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
}


resource "azurerm_public_ip" "this" {
  allocation_method   = "Static"
  location            = var.location
  name                = "fw-pip-${random_string.acr_suffix.result}"
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall" "this" {
  location            = var.location
  name                = "fw-${random_string.acr_suffix.result}"
  resource_group_name = var.resource_group_name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  dns_proxy_enabled   = true
  tags                = var.tags

  ip_configuration {
    name                 = "configuration"
    public_ip_address_id = azurerm_public_ip.this.id
    subnet_id            = azurerm_subnet.firewall.id
  }
}

resource "azurerm_route_table" "this" {
  location            = var.location
  name                = "rt-${random_string.acr_suffix.result}"
  resource_group_name = var.resource_group_name
  tags                = var.tags

  route {
    address_prefix         = "0.0.0.0/0"
    name                   = "internet"
    next_hop_in_ip_address = azurerm_firewall.this.ip_configuration[0].private_ip_address
    next_hop_type          = "VirtualAppliance"
  }
  route {
    address_prefix = "${azurerm_public_ip.this.ip_address}/32"
    name           = "internal"
    next_hop_type  = "Internet"
  }
}


resource "azurerm_firewall_network_rule_collection" "this" {
  action              = "Allow"
  azure_firewall_name = azurerm_firewall.this.name
  name                = "aksfwnr-${random_string.acr_suffix.result}"
  priority            = 100
  resource_group_name = var.resource_group_name

  rule {
    destination_ports = [
      "1194",
    ]
    name = "apiudp"
    protocols = [
      "UDP",
    ]
    destination_addresses = [
      "AzureCloud.${var.location}",
    ]
    source_addresses = [
      "*",
    ]
  }
  rule {
    destination_ports = [
      "9000",
    ]
    name = "apitcp"
    protocols = [
      "TCP",
    ]
    destination_addresses = [
      "AzureCloud.${var.location}",
    ]
    source_addresses = [
      "*",
    ]
  }
  rule {
    destination_ports = [
      "123",
    ]
    name = "time"
    protocols = [
      "UDP",
    ]
    destination_fqdns = [
      "ntp.ubuntu.com",
    ]
    source_addresses = [
      "*",
    ]
  }
  rule {
    destination_ports = [
      "443",
    ]
    name = "ghcr"
    protocols = [
      "TCP",
    ]
    destination_fqdns = [
      "ghcr.io",
      "pkg-containers.githubusercontent.com",
    ]
    source_addresses = [
      "*",
    ]
  }
  rule {
    destination_ports = [
      "443",
    ]
    name = "docker"
    protocols = [
      "TCP",
    ]
    destination_fqdns = [
      "docker.io",
      "registry-1.docker.io",
      "production.cloudflare.docker.com",
    ]
    source_addresses = [
      "*",
    ]
  }
}


resource "azurerm_firewall_application_rule_collection" "this" {
  action              = "Allow"
  azure_firewall_name = azurerm_firewall.this.name
  name                = "aksfwar-${random_string.acr_suffix.result}"
  priority            = 100
  resource_group_name = var.resource_group_name

  rule {
    name      = "fqdn"
    fqdn_tags = ["AzureKubernetesService"]
    source_addresses = [
      "*",
    ]
  }
}

resource "azurerm_subnet_route_table_association" "this" {
  route_table_id = azurerm_route_table.this.id
  subnet_id      = azurerm_subnet.aks.id

  depends_on = [
    azurerm_firewall_application_rule_collection.this,
    azurerm_firewall_network_rule_collection.this,
  ]
}