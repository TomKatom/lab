# Lab

## Overview

This project is the IaC repo for my personal server.  
I have a dedicated server in OVH with the following specs: E5-1650v4 with 128GB RAM and the 2x500GB NVMe + 2x2TB HDD  
No KVM acesss.

My personal server is a seebox and a media streaming solution, Plex for streaming and *arrs for accquistion.

## Prior Setup

These steps were already done in a non-IaC way.
- Clean proxmox install
- The 2x500GB NVMEs are in a zfs pool called rpool, dataset created and mounted as the root filesystem of proxmox.

## Guidelines

- Most things should be done following IaC principles, no manual work on the server unless it is way to complicated to automate.
- Use best practice tools and solutions.
- SecOps is important, expose only what is necessary, harden hosted services and OS.
- Never commit secrets, use some sort of secret management.
- Don't repeat/duplicate configuration details, define variables in a single place.
- Use GitOps, I want my repo to be the single source of truth.
- Trunk based development
- Document the workflow in a form of documentation also tracked by git

## Cloud Dependencies

External services used:
- Cloudflare: DNS provider
- GitHub: Repository and CI/CD
