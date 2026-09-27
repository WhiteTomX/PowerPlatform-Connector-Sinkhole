# Flex Consumption apps run directly from a zip in blob storage (no ARM/Terraform
# inline-content deploy like the old Y1 plan) - so the whole of src/ (host.json plus
# one folder per function, each with function.json + code) gets zipped and uploaded
# here, and every catcher app below points at the same blob since they all run the
# identical dump function.
data "archive_file" "function_package" {
  type        = "zip"
  source_dir  = "${path.module}/${var.function_source_path}"
  output_path = "${path.module}/dist/function-package.zip"
}

resource "azurerm_storage_blob" "function_package" {
  name                 = "function-package.zip"
  storage_container_id = azurerm_storage_container.deployment_package.id
  type                 = "Block"
  source               = data.archive_file.function_package.output_path
  content_md5          = data.archive_file.function_package.output_md5
}
