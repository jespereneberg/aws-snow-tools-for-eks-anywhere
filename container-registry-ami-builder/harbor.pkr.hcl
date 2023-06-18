packer {
  required_plugins {
    amazon = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
}

variables {
  region        = "us-west-2"
  instance_type = "t2.large"
  subnet_id     = ""
  volume_size   = 30
  source_ami    = ""
  ami_name      = "ami-snow-harbor"
  harbor_version= "v2.7.0"
}

source "amazon-ebs" "harbor-al2" {
  ami_name      = var.ami_name
  source_ami    = var.source_ami
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  region        = var.region
  ssh_username  = "ec2-user"

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.volume_size
    delete_on_termination = true
  }
}

build {
  sources = [
    "source.amazon-ebs.harbor-al2"
  ]

  provisioner "file" {
    source      = "./images"
    destination = "/tmp/images"
  }

  provisioner "file" {
    source      = "./harbor-configuration.sh"
    destination = "/tmp/harbor-configuration.sh"
  }

  provisioner "file" {
    source      = "./images.txt"
    destination = "/tmp/images.txt"
  }

  provisioner "file" {
    source      = "../setup-tools/dni-configuration.sh"
    destination = "/tmp/dni-configuration.sh"
  }

  provisioner "shell" {
    inline = [
      "mv /tmp/images ~/",
      "mv /tmp/harbor-configuration.sh ~/",
      "mv /tmp/images.txt ~/",
      "mv /tmp/dni-configuration.sh ~/",
      "chmod +x ~/*.sh" 
    ]
  }

  provisioner "shell" {
    environment_vars = [
        "version=${var.harbor_version}"
    ]
    scripts = [
      "harbor-image-build.sh"
    ]
  }
}
