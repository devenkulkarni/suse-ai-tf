data "aws_caller_identity" "current" {}

locals {
  private_ssh_key_path = var.ssh_private_key_path == null ? "${path.cwd}/${var.prefix}-ssh_private_key.pem" : var.ssh_private_key_path
  public_ssh_key_path  = var.ssh_public_key_path == null ? "${path.cwd}/${var.prefix}-ssh_public_key.pem" : var.ssh_public_key_path
  instance_count       = 1
  ssh_username         = var.certified_os_image ? "opensuse" : "ec2-user"
  certified_image_name = "opensuse-leap-15-6-suse-ai-tf-cloud-image.x86_64.vhd"
  certified_image_url  = var.certified_os_image ? "https://github.com/devenkulkarni/suse-ai-tf/releases/download/${var.certified_os_image_tag}/${local.certified_image_name}" : null

  username    = element(split("/", data.aws_caller_identity.current.arn), length(split("/", data.aws_caller_identity.current.arn)) - 1)
  common_tags = {
    Owner = local.username
 }
}

resource "tls_private_key" "ssh_private_key" {
  count     = var.create_ssh_key_pair ? 1 : 0
  algorithm = "ED25519"
}

resource "aws_key_pair" "generated_key" {
  count      = var.create_ssh_key_pair ? 1 : 0
  key_name   = "${var.prefix}-opensuse-key"
  public_key = tls_private_key.ssh_private_key[0].public_key_openssh
}

resource "local_file" "private_key_pem" {
  count           = var.create_ssh_key_pair ? 1 : 0
  filename        = local.private_ssh_key_path
  content         = tls_private_key.ssh_private_key[0].private_key_openssh
  file_permission = "0600"
}

# Code for downloading the custom build OS image:

resource "null_resource" "download_certified_vhd" {
  count = var.certified_os_image ? 1 : 0
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      if [ ! -f "${path.cwd}/${local.certified_image_name}" ]; then
        echo "Downloading certified VHD..."
        curl -L -o "${path.cwd}/${local.certified_image_name}" "${local.certified_image_url}"
      else
        echo "Certified VHD already exists, skipping download"
      fi
    EOT
  }
}

# Create a S3 Bucket to store the OS image:

resource "aws_s3_bucket" "images" {
  count  = var.certified_os_image ? 1 : 0
  bucket = "opensuse-vhd-${var.prefix}"

  tags = local.common_tags
}

# Upload the OS image to the S3 Bucket:

resource "aws_s3_object" "vhd" {
  count      = var.certified_os_image ? 1 : 0
  depends_on = [null_resource.download_certified_vhd]
  bucket     = aws_s3_bucket.images[0].id
  key        = "opensuse-harv.vhd"
  source     = "${path.cwd}/${local.certified_image_name}"
}

# Create IAM role and Policy needed for S3 Bucket access:
resource "aws_iam_role" "vmimport" {
  count = var.certified_os_image ? 1 : 0
  name  = "vmimport"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vmie.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "vmimport" {
  count = var.certified_os_image ? 1 : 0
  name  = "vmimport"
  role  = aws_iam_role.vmimport[0].id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          aws_s3_bucket.images[0].arn,
          "${aws_s3_bucket.images[0].arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "ec2:ModifySnapshotAttribute",
          "ec2:CopySnapshot",
          "ec2:RegisterImage",
          "ec2:Describe*"
        ],
        Resource = "*"
      }
    ]
  })
}

# Create EBS snapshot to import image from S3 Bucket:

resource "aws_ebs_snapshot_import" "opensuse_snapshot" {
  count       = var.certified_os_image ? 1 : 0
  description = "Opensuse Cerfied Image for SUSE AI TF"
  role_name   = aws_iam_role.vmimport[0].name
  lifecycle {
    ignore_changes = [description]
  }
  disk_container {
    format = "VHD"
    user_bucket {
      s3_bucket = aws_s3_bucket.images[0].id
      s3_key    = aws_s3_object.vhd[0].key
    }
  }
  depends_on = [aws_s3_object.vhd]
}

# Code to add/register AMI using the custom build OS image

resource "aws_ami" "opensuse_ami" {
  count               = var.certified_os_image ? 1 : 0
  name                = "opensuse-suse-ai-tf-ami"
  virtualization_type = "hvm"
  root_device_name    = "/dev/xvda"
  ena_support         = true
  ebs_block_device {
    device_name = "/dev/xvda"
    snapshot_id = aws_ebs_snapshot_import.opensuse_snapshot[0].id
    volume_size = 2
    volume_type = "gp3"
  }
  tags = merge(local.common_tags, { Name = "${var.prefix}-ami" })
}

# VPC
resource "aws_vpc" "default_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.prefix}-vpc" })
}

# Internet Gateway
resource "aws_internet_gateway" "default_igw" {
  vpc_id = aws_vpc.default_vpc.id

  tags = merge(local.common_tags, { Name = "${var.prefix}-igw" })
}

# Route Table
resource "aws_route_table" "default_rt" {
  vpc_id = aws_vpc.default_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.default_igw.id
  }

  tags = merge(local.common_tags, { Name = "${var.prefix}-rt" })
}

# Subnet
resource "aws_subnet" "default_subnet" {
  vpc_id                  = aws_vpc.default_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = merge(local.common_tags, { Name = "${var.prefix}-subnet" })
}

# Associate Route Table with Subnet
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.default_subnet.id
  route_table_id = aws_route_table.default_rt.id
}


resource "aws_security_group" "default" {
  name        = "${var.prefix}-sg"
  description = "Allow RKE2 and SSH"
  vpc_id      = aws_vpc.default_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "RKE2 API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "ec2_eip" {
  count  = local.instance_count
  domain = "vpc"
  tags = {
    Name = "${var.prefix}-eip-${count.index}"
  }
}

resource "aws_eip_association" "eip_assoc" {
  count         = local.instance_count
  instance_id   = aws_instance.opensuse_gpu[count.index].id
  allocation_id = aws_eip.ec2_eip[count.index].id
}

resource "aws_instance" "opensuse_gpu" {
  count = local.instance_count
  # ami           = data.aws_ami.opensuse_leap.id
  ami           = var.certified_os_image ? aws_ami.opensuse_ami[0].id : data.aws_ami.opensuse_leap[0].id
  instance_type = var.instance_type

  key_name               = var.create_ssh_key_pair ? aws_key_pair.generated_key[0].key_name : var.existing_key_name
  vpc_security_group_ids = [aws_security_group.default.id]
  subnet_id              = aws_subnet.default_subnet.id

  root_block_device {
    volume_size = var.os_disk_size
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/scripts/startupscript.tftpl", {})

  tags = merge(local.common_tags, { Name = "${var.prefix}-opensuse-rke2" })
}

resource "null_resource" "wait_for_gpu" {
  count = local.instance_count
  depends_on = [aws_instance.opensuse_gpu, aws_eip_association.eip_assoc]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = aws_eip.ec2_eip[count.index].public_ip
      timeout     = "15m"
    }

    inline = [
      "echo 'Waiting for GPU Driver installation to complete...'",
      # This loop waits for nvidia-smi to be available in the PATH
      # timeout 600 ensures it doesn't loop forever (10 minutes max)
      "timeout 600 bash -c 'until command -v nvidia-smi &> /dev/null; do echo \"Still waiting for nvidia-smi...\"; sleep 20; done'",
      "echo 'GPU Driver detected!'",
      "nvidia-smi",
      "echo 'Setup script verified. Environment is ready.'"
    ]
  }
}

resource "null_resource" "rke2_installation" {
  count = local.instance_count
  depends_on = [null_resource.wait_for_gpu]

  provisioner "remote-exec" {
    inline = [
      templatefile("${path.module}/scripts/rke2-localpath-install.sh", {
        public_ip    = aws_eip.ec2_eip[count.index].public_ip
        rke2_version = var.rke2_version
      })
    ]

    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = aws_eip.ec2_eip[count.index].public_ip
    }
  }
}

resource "null_resource" "retrieve_kubeconfig" {
  depends_on = [null_resource.rke2_installation]

  provisioner "remote-exec" {
    inline = [
      "sudo cp /etc/rancher/rke2/rke2.yaml /tmp/rke2.yaml",
      "sudo chown ${local.ssh_username} /tmp/rke2.yaml",
      "sudo chmod 644 /tmp/rke2.yaml"
    ]

    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = aws_eip.ec2_eip[0].public_ip
    }
  }

  provisioner "local-exec" {
    command = <<EOT
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -i ${local.private_ssh_key_path} \
          ${local.ssh_username}@${aws_eip.ec2_eip[0].public_ip}:/tmp/rke2.yaml \
          ./kubeconfig-rke2.yaml
      
      # Detect OS and run the correct sed command
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/127.0.0.1/${aws_eip.ec2_eip[0].public_ip}/g" ./kubeconfig-rke2.yaml
      else
        sed -i "s/127.0.0.1/${aws_eip.ec2_eip[0].public_ip}/g" ./kubeconfig-rke2.yaml
      fi
      
      echo "Kubeconfig successfully retrieved and updated."
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ./kubeconfig-rke2.yaml"
  }
}

#resource "null_resource" "cleanup_certified_vhd" {
#  depends_on = [null_resource.retrieve_kubeconfig]
#  count      = var.certified_os_image ? 1 : 0
#  provisioner "local-exec" {
#    when    = destroy
#    command = "rm ${path.cwd}/opensuse-leap-15-6-suse-ai-tf-cloud-image.x86_64.vhd"
#  }
#}
