# 1

provider "azurerm" {
  # whilst the `version` attribute is optional, we recommend pinning to a given version of the Provider
  version = "=1.38.0"
}

provider "azuread" {
  version = "~> 0.3"
}

terraform {
  backend "azurerm" {
    resource_group_name  = "tf-rg"
    storage_account_name = "tfstatestac"
    container_name       = "tfstate"
    key                  = "org.terraform.tfstate"
  }
}

data "azurerm_subscription" "current" {}

# Resource Group creation
resource "azurerm_resource_group" "k8s" {
  name     = "${var.rg-name}"
  location = "${var.location}"
}

# 2

# AAD K8s Backend App

resource "azuread_application" "aks-aad-srv" {
  name                       = "${var.clustername}srv"
  homepage                   = "https://${var.clustername}srv"
  identifier_uris            = ["https://${var.clustername}srv"]
  reply_urls                 = ["https://${var.clustername}srv"]
  type                       = "webapp/api"
  group_membership_claims    = "All"
  available_to_other_tenants = false
  oauth2_allow_implicit_flow = false
  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000"
    resource_access {
      id   = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"
      type = "Role"
    }
    resource_access {
      id   = "06da0dbc-49e2-44d2-8312-53f166ab848a"
      type = "Scope"
    }
    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
      type = "Scope"
    }
  }
  required_resource_access {
    resource_app_id = "00000002-0000-0000-c000-000000000000"
    resource_access {
      id   = "311a71cc-e848-46a1-bdf8-97ff7156d8e6"
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "aks-aad-srv" {
  application_id = "${azuread_application.aks-aad-srv.application_id}"
}

resource "random_password" "aks-aad-srv" {
  length  = 16
  special = true
}

resource "azuread_application_password" "aks-aad-srv" {
  application_object_id = "${azuread_application.aks-aad-srv.object_id}"
  value                 = "${random_password.aks-aad-srv.result}"
  end_date              = "2024-01-01T01:02:03Z"
}

# AAD AKS kubectl app

resource "azuread_application" "aks-aad-client" {
  name       = "${var.clustername}client"
  homepage   = "https://${var.clustername}client"
  reply_urls = ["https://${var.clustername}client"]
  type       = "native"
  required_resource_access {
    resource_app_id = "${azuread_application.aks-aad-srv.application_id}"
    resource_access {
      id   = "${azuread_application.aks-aad-srv.oauth2_permissions.0.id}"
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "aks-aad-client" {
  application_id = "${azuread_application.aks-aad-client.application_id}"
}

# 3

# AAD K8s cluster admin group / AAD

resource "azuread_group" "aks-aad-clusteradmins" {
  name = "${var.clustername}clusteradmin"
}

# 4

# Service Principal for AKS

resource "azuread_application" "aks_sp" {
  name                       = "${var.clustername}"
  homepage                   = "https://${var.clustername}"
  identifier_uris            = ["https://${var.clustername}"]
  reply_urls                 = ["https://${var.clustername}"]
  available_to_other_tenants = false
  oauth2_allow_implicit_flow = false
}

resource "azuread_service_principal" "aks_sp" {
  application_id = "${azuread_application.aks_sp.application_id}"
}

resource "random_password" "aks_sp_pwd" {
  length  = 16
  special = true
}

resource "azuread_service_principal_password" "aks_sp_pwd" {
  service_principal_id = "${azuread_service_principal.aks_sp.id}"
  value                = "${random_password.aks_sp_pwd.result}"
  end_date             = "2024-01-01T01:02:03Z"
}

resource "azurerm_role_assignment" "aks_sp_role_assignment" {
  scope                = "${data.azurerm_subscription.current.id}"
  role_definition_name = "Contributor"
  principal_id         = "${azuread_service_principal.aks_sp.id}"

  depends_on = [
    azuread_service_principal_password.aks_sp_pwd
  ]
}

# 5

# K8s cluster

resource "null_resource" "delay_before_consent" {
  provisioner "local-exec" {
    command = "sleep 60"
  }
  depends_on = [
    azuread_service_principal.aks-aad-srv,
    azuread_service_principal.aks-aad-client
  ]
}

resource "null_resource" "grant_srv_admin_constent" {
  provisioner "local-exec" {
    command = "az ad app permission admin-consent --id ${azuread_application.aks-aad-srv.application_id}"
  }
  depends_on = [
    null_resource.delay_before_consent
  ]
}
resource "null_resource" "grant_client_admin_constent" {
  provisioner "local-exec" {
    command = "az ad app permission admin-consent --id ${azuread_application.aks-aad-client.application_id}"
  }
  depends_on = [
    null_resource.delay_before_consent
  ]
}

resource "null_resource" "delay" {
  provisioner "local-exec" {
    command = "sleep 60"
  }
  depends_on = [
    null_resource.grant_srv_admin_constent,
    null_resource.grant_client_admin_constent
  ]
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.clustername}"
  location            = "${var.location}"
  resource_group_name = "${var.rg-name}"
  dns_prefix          = "${var.clustername}"

  default_node_pool {
    name            = "default"
    type            = "VirtualMachineScaleSets"
    node_count      = 2
    vm_size         = "Standard_B2s"
    os_disk_size_gb = 30
    max_pods        = 50
  }
  service_principal {
    client_id     = "${azuread_application.aks_sp.application_id}"
    client_secret = "${random_password.aks_sp_pwd.result}"
  }
  role_based_access_control {
    azure_active_directory {
      client_app_id     = "${azuread_application.aks-aad-client.application_id}"
      server_app_id     = "${azuread_application.aks-aad-srv.application_id}"
      server_app_secret = "${random_password.aks-aad-srv.result}"
      tenant_id         = "${data.azurerm_subscription.current.tenant_id}"
    }
    enabled = true
  }
  depends_on = [
    null_resource.delay,
    azuread_service_principal.aks-aad-srv,
    azurerm_role_assignment.aks_sp_role_assignment,
    azuread_service_principal_password.aks_sp_pwd
  ]
}

# 6

# Role assignment

# User ADMIN credentials

provider "kubernetes" {
  host                   = "${azurerm_kubernetes_cluster.aks.kube_admin_config.0.host}"
  client_certificate     = "${base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config.0.client_certificate)}"
  client_key             = "${base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config.0.client_key)}"
  cluster_ca_certificate = "${base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config.0.cluster_ca_certificate)}"
}

# Cluster role binding to AAD group


resource "kubernetes_cluster_role_binding" "aad_integration" {
  metadata {
    name = "${var.clustername}admins"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind = "Group"
    name = "${azuread_group.aks-aad-clusteradmins.id}"
  }
  depends_on = [
    azurerm_kubernetes_cluster.aks
  ]
}



# Output
output "server-app-id" {
  value = "${azuread_application.aks-aad-srv.application_id}"
}
output "client-app-id" {
  value = "${azuread_application.aks-aad-client.application_id}"
}
