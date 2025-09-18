#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------
# Speedy mirrors & apt tuning
# --------------------------------------------------------------------
sudo sed -i 's|http://us.archive.ubuntu.com/ubuntu|http://mirror.cse.iitk.ac.in/ubuntu|g' /etc/apt/sources.list || true

sudo tee /etc/apt/apt.conf.d/99-speed >/dev/null <<'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::ForceIPv4 "true";
Acquire::Languages "none";
APT::Install-Recommends "false";
Dpkg::Use-Pty "0";
Acquire::Queue-Mode "host";
EOF

sudo apt-get clean
sudo apt-get update -y
sudo apt-get install -y ansible-core

# --------------------------------------------------------------------
# Inventory & Ansible config
# --------------------------------------------------------------------
mkdir -p /home/vagrant/ansible

cat <<EOF | sudo tee /home/vagrant/ansible/inventory.ini
[runner]
localhost ansible_connection=local

[workers]
worker1 ansible_host=172.20.0.11 ansible_user=root
worker2 ansible_host=172.20.0.12 ansible_user=root

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

cat <<EOF | sudo tee /home/vagrant/ansible/ansible.cfg
[defaults]
inventory = ./inventory.ini
remote_user = root
host_key_checking = False
deprecation_warnings = False
interpreter_python = auto_silent

[privilege_escalation]
become = false

[ssh_connection]
ssh_args = -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
EOF

sudo chown -R vagrant:vagrant /home/vagrant/ansible

# --------------------------------------------------------------------
# Task 1 - Install NGINX
# --------------------------------------------------------------------
cat <<EOF > /home/vagrant/ansible/install_nginx.yml
---
- name: Install nginx on workers
  hosts: workers
  become: yes
  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes

    - name: Install nginx
      apt:
        name: nginx
        state: present

    - name: Ensure nginx is running
      service:
        name: nginx
        state: started
        enabled: yes
EOF

# --------------------------------------------------------------------
# Task 2 - Create DevOps user
# --------------------------------------------------------------------
cat <<EOF > /home/vagrant/ansible/user_add.yml
---
- name: Create DevOps user
  hosts: workers
  become: yes
  tasks:
    - name: Ensure user 'devops' exists
      user:
        name: devops
        shell: /bin/bash
        groups: sudo
        state: present
EOF

# --------------------------------------------------------------------
# Task 3 - Copy index.html
# --------------------------------------------------------------------
cat <<EOF > /home/vagrant/ansible/copy_index.yml
---
- name: Deploy simple index.html and restart nginx
  hosts: workers
  become: yes
  tasks:
    - name: Place index.html
      copy:
        dest: /var/www/html/index.html
        content: |
          <h1>Welcome to Jeevi Academy</h1>
          <p>Deployed on {{ inventory_hostname }}</p>

    - name: Restart nginx
      service:
        name: nginx
        state: restarted
EOF

# --------------------------------------------------------------------
# Task 4 - Stop NGINX
# --------------------------------------------------------------------
cat <<EOF > /home/vagrant/ansible/stop_nginx.yml
---
- name: Stop nginx on workers
  hosts: workers
  become: yes
  tasks:
    - name: Stop nginx by killing the process
      shell: pkill nginx || true
      changed_when: false
      ignore_errors: yes

    - name: Verify nginx is not running
      shell: pgrep nginx
      register: nginx_running
      failed_when: false
      changed_when: false

    - name: Show nginx status
      debug:
        msg: "NGINX is {{ 'still running' if nginx_running.rc == 0 else 'stopped' }} on {{ inventory_hostname }}"
EOF

# --------------------------------------------------------------------
# Task 5 - Health check
# --------------------------------------------------------------------
cat <<EOF > /home/vagrant/ansible/healthcheck.yml
---
- name: Check NGINX status
  hosts: workers
  become: yes
  tasks:
    - name: Check if nginx process is running
      shell: pgrep nginx
      register: nginx_process
      ignore_errors: yes
      changed_when: false

    - name: Get container IP address
      shell: hostname -I | awk '{print $1}'
      register: container_ip
      changed_when: false

    - name: Show nginx status and IP
      debug:
        msg: "NGINX is {{ 'running' if nginx_process.rc == 0 else 'not running' }} on {{ inventory_hostname }} ({{ container_ip.stdout }})"

    - name: Request homepage if nginx is running
      uri:
        url: "http://{{ container_ip.stdout }}/"
        return_content: yes
      register: homepage
      changed_when: false
      when: nginx_process.rc == 0
      ignore_errors: yes

    - name: Show HTTP status if nginx is running
      debug:
        msg: "HTTP status from {{ inventory_hostname }} ({{ container_ip.stdout }}) is {{ homepage.status }}"
      when: nginx_process.rc == 0

    - name: Ensure nginx is running and status is 200 OK
      assert:
        that:
          - nginx_process.rc == 0
          - homepage.status == 200
        fail_msg: "NGINX is not running or not accessible on {{ inventory_hostname }} ({{ container_ip.stdout }})"
        success_msg: "NGINX is running and accessible on {{ inventory_hostname }} ({{ container_ip.stdout }})"
      when: nginx_process.rc == 0
EOF

# --------------------------------------------------------------------
# Task 6 - Install GitHub Runner
# --------------------------------------------------------------------
cat <<EOF > /home/vagrant/ansible/install_github_runner.yml
---
- name: Install GitHub Actions Runner
  hosts: all
  become: yes
  vars:
    github_repo: "{{ lookup('env','GITHUB_REPO') }}"
    runner_version: "2.328.0"
    runner_dir: "/opt/actions-runner"
    github_pat: "{{ lookup('env','GITHUB_PAT') }}"

  tasks:
    - name: Install dependencies
      apt:
        name: "{{ item }}"
        state: present
        update_cache: yes
      loop:
        - curl
        - tar
        - jq

    - name: Create runner directory
      file:
        path: "{{ runner_dir }}"
        state: directory
        owner: vagrant
        group: vagrant
        mode: '0755'

    - name: Download GitHub Actions runner
      get_url:
        url: "https://github.com/actions/runner/releases/download/v{{ runner_version }}/actions-runner-linux-x64-{{ runner_version }}.tar.gz"
        dest: "{{ runner_dir }}/runner.tar.gz"
        mode: '0644'

    - name: Extract GitHub runner
      command: tar xzf runner.tar.gz
      args:
        chdir: "{{ runner_dir }}"
      creates: "{{ runner_dir }}/config.sh"

    - name: Request registration token from GitHub API
      uri:

