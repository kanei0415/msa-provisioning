output "inventory_path" {
  value       = local_file.inventory.filename
  description = "書き出された inventory.ini の絶対パス"
}
