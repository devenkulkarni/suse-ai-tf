locals {
  private_ssh_key_path = var.ssh_private_key_path == null ? "${path.cwd}/${var.prefix}-ssh_private_key.pem" : var.ssh_private_key_path
  public_ssh_key_path  = var.ssh_public_key_path == null ? "${path.cwd}/${var.prefix}-ssh_public_key.pem" : var.ssh_public_key_path
  instance_count       = 1
  # openSUSE Marketplace default user
  ssh_username = "ec2-user"
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

# VPC
resource "aws_vpc" "default_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.prefix}-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "default_igw" {
  vpc_id = aws_vpc.default_vpc.id

  tags = {
    Name = "${var.prefix}-igw"
  }
}

# Route Table
resource "aws_route_table" "default_rt" {
  vpc_id = aws_vpc.default_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.default_igw.id
  }

  tags = {
    Name = "${var.prefix}-rt"
  }
}

# Subnet
resource "aws_subnet" "default_subnet" {
  vpc_id                  = aws_vpc.default_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "${var.prefix}-subnet"
  }
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

#resource "aws_eip" "ec2_eip" {
#  domain = "vpc"
#  tags = {
#    Name = "${var.prefix}-eip"
#  }
#}

#resource "aws_eip_association" "eip_assoc" {
#  instance_id   = aws_instance.opensuse_gpu.id
#  allocation_id = aws_eip.ec2_eip.id
#}

resource "aws_instance" "opensuse_gpu" {
  count         = local.instance_count
  ami           = data.aws_ami.opensuse_leap.id
  instance_type = var.instance_type

  key_name               = var.create_ssh_key_pair ? aws_key_pair.generated_key[0].key_name : var.existing_key_name
  vpc_security_group_ids = [aws_security_group.default.id]
  subnet_id              = aws_subnet.default_subnet.id

  root_block_device {
    volume_size = var.os_disk_size
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/scripts/startupscript.tftpl", {})

  tags = {
    Name = "${var.prefix}-opensuse-rke2"
  }
}

resource "null_resource" "wait_for_gpu" {
  depends_on = [aws_instance.opensuse_gpu]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = aws_instance.opensuse_gpu[0].public_ip
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
  depends_on = [null_resource.wait_for_gpu]

  provisioner "remote-exec" {
    inline = [
      templatefile("${path.module}/scripts/rke2-localpath-install.sh", {
        public_ip    = aws_instance.opensuse_gpu[0].public_ip
        rke2_version = var.rke2_version
      })
    ]

    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = aws_instance.opensuse_gpu[0].public_ip
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
      host        = aws_instance.opensuse_gpu[0].public_ip
    }
  }

  provisioner "local-exec" {
    command = <<EOT
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -i ${local.private_ssh_key_path} \
          ${local.ssh_username}@${aws_instance.opensuse_gpu[0].public_ip}:/tmp/rke2.yaml \
          ./kubeconfig-rke2.yaml
      
      # Detect OS and run the correct sed command
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/127.0.0.1/${aws_instance.opensuse_gpu[0].public_ip}/g" ./kubeconfig-rke2.yaml
      else
        sed -i "s/127.0.0.1/${aws_instance.opensuse_gpu[0].public_ip}/g" ./kubeconfig-rke2.yaml
      fi
      
      echo "Kubeconfig successfully retrieved and updated."
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ./kubeconfig-rke2.yaml"
  }
}
