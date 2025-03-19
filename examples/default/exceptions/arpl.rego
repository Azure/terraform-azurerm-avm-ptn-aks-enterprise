package Azure_Proactive_Resiliency_Library_v2
 
import rego.v1
 
exception contains rules if {
  rules = ["configure_aks_default_node_pool_zones", "public_ip_use_standard_sku_and_zone_redundant_ip"]
}