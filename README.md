# Architecture 3-tiers sécurisée pour une application de streaming vidéo

Ce dépôt contient une architecture AWS complète, provisionnée avec Terraform et configurée avec Ansible, pour une petite application de streaming vidéo en direct. Le projet met l'accent sur la sécurité réseau et la gestion des identités plutôt que sur les fonctionnalités applicatives.

## Contexte

Ce travail est une reconstruction personnelle, faite seule de bout en bout, inspirée d'un projet TP réalisé a Telecom paris. L'objectif était de reprendre la même logique d'architecture pour la maîtriser en profondeur, comprendre chaque choix technique, et l'étendre au-delà de ce qui avait été fait en groupe, notamment sur la partie sécurité réseau et gestion des identités.

## Architecture

L'application est découpée en trois tiers, chacun avec un rôle strictement défini et des accès réseau limités au minimum nécessaire.

**Tier 1, le frontend.** Une instance EC2 qui fait tourner deux conteneurs Docker sur un réseau interne dédié. Le premier est un WAF (ModSecurity avec le jeu de règles OWASP Core Rule Set), seul point d'entrée HTTP de l'instance. Le second est NGINX avec le module RTMP, qui reçoit le flux vidéo et le convertit en HLS pour la diffusion aux navigateurs. Cette instance est placée dans le subnet public, choix assumé pour garder un accès direct à internet sans dépendre d'un NAT Gateway payant.

**Tier 2, le streaming.** Une instance EC2 qui fait tourner FFmpeg dans une boucle continue, générant un signal de test et le poussant en RTMP vers le Tier 1. Elle vit dans un subnet privé, sans IP publique, et n'accepte aucune connexion entrante.

**Tier 3, la base de données.** Une instance EC2 avec PostgreSQL, destinée à stocker les métadonnées de l'application (catalogue de vidéos, statistiques). Elle vit dans le même subnet privé que le Tier 2, et n'accepte de connexion que depuis le Tier 1.

Devant le Tier 1, un Application Load Balancer sert de point d'entrée public pour les utilisateurs.

L'administration des trois instances se fait exclusivement via EC2 Instance Connect Endpoint. Aucune des trois n'a de port SSH ouvert sur son Security Group, l'accès passe par un tunnel géré par AWS, sans clé exposée ni port public à surveiller.

## Stack technique

- **Terraform** pour tout le provisioning : VPC, subnets, tables de routage, Security Groups, instances EC2, rôle IAM, paramètre SSM, Load Balancer, endpoint EICE.
- **Ansible** pour la configuration des trois serveurs, un rôle par tier.
- **Docker** sur le Tier 1, pour isoler le WAF et NGINX chacun dans leur conteneur.
- **AWS Systems Manager Parameter Store** pour stocker le mot de passe de la base de données, jamais écrit en clair dans le code.

## Choix de sécurité et pourquoi

| Choix | Raison |
|---|---|
| Segmentation par Security Groups référencés entre eux, jamais par plage d'IP | Chaque règle suit l'instance concernée plutôt qu'une adresse, plus robuste et plus lisible |
| Tier 2 et Tier 3 dans un subnet privé, sans IP publique | Réduction de la surface d'attaque au-delà du simple filtrage par pare-feu |
| Accès administrateur via EC2 Instance Connect Endpoint, aucun port 22 ouvert | Élimine complètement la surface d'attaque SSH classique |
| Rôle IAM du frontend limité à une seule action sur une seule ressource (lire un paramètre SSM précis) | Application du principe de moindre privilège, même en cas de compromission de l'instance |
| Mot de passe de la base stocké dans SSM, jamais dans le code ni dans Git | Aucun secret ne transite ni ne reste dans l'historique du dépôt |
| WAF open source (ModSecurity, OWASP Core Rule Set) plutôt qu'AWS WAF | AWS WAF n'a aucun palier gratuit, cette alternative offre la même protection conceptuelle sans coût |
| Base de données auto-gérée plutôt qu'Amazon RDS | Choix pédagogique, pour rester sur des briques déjà maîtrisées (EC2, Ansible) plutôt que d'ajouter un nouveau service sous contrainte de temps |
| Load Balancer en HTTP plutôt qu'HTTPS | Absence de nom de domaine personnel pour valider un certificat ACM, compromis assumé pour la démonstration |

## Reproduire ce lab

### Prérequis

- Un compte AWS avec une alerte de budget configurée
- Terraform et l'AWS CLI installés et configurés avec un utilisateur IAM dédié (pas le compte root)
- Ansible installé, avec les collections `community.postgresql`, `community.docker` et `amazon.aws`
- Python avec `boto3` et `botocore` installés en local, nécessaires pour la lecture du secret SSM par Ansible

### Déploiement de l'infrastructure

```bash
terraform init
terraform plan
terraform apply
```

### Configuration de l'accès SSH via EICE

Ajouter dans `~/.ssh/config` :

```
Host i-*
  ProxyCommand sh -c "aws ec2-instance-connect open-tunnel --instance-id %h"
  User ubuntu
  IdentityFile ~/streaming-lab/streaming-key.pem
  StrictHostKeyChecking accept-new
```

### Configuration des serveurs

```bash
ansible-playbook -i inventory.ini playbook.yml
```

### Nettoyage

```bash
terraform destroy
```

## Vérifications effectuées

- Accès au site via le nom DNS du Load Balancer : réussi, code 200
- Tentative d'injection SQL envoyée via l'URL publique : bloquée par le WAF, code 403
- Connexion directe au Tier 2 et au Tier 3 depuis internet : impossible, aucune IP publique
- Connexion administrateur aux trois instances via EICE : réussie, sans aucun port 22 ouvert
- Flux vidéo généré sur le Tier 2, poussé en RTMP, converti en HLS sur le Tier 1, et lu dans VLC via l'URL publique du Load Balancer : confirmé de bout en bout

## Ce que je changerais pour une mise en production réelle

- Basculer aussi le Tier 1 en subnet privé, avec un NAT Gateway pour l'accès sortant, plutôt que de le garder public pour simplifier ce lab
- Remplacer le WAF open source par AWS WAF avec ses Managed Rule Groups, pour bénéficier de mises à jour de règles sans les maintenir soi-même
- Remplacer PostgreSQL auto-géré par Amazon RDS, avec chiffrement au repos et sauvegardes automatiques
- Ajouter un tier d'ingestion séparé pour la vidéo, exposé publiquement mais protégé par une clé de stream, derrière un Network Load Balancer plutôt qu'un Application Load Balancer, pour accepter des flux venant de sources externes réelles
- Stocker le secret de la base dans AWS Secrets Manager avec rotation automatique, plutôt qu'un paramètre SSM statique
- Ajouter un Auto Scaling Group derrière le Load Balancer, pour que celui-ci serve réellement à répartir la charge entre plusieurs instances, pas seulement à surveiller la santé d'une seule
- Mettre en place une supervision centralisée des logs de chaque tier, pour détecter une intrusion ou une anomalie en temps réel
- Utiliser un vrai nom de domaine avec un certificat ACM, pour que le Load Balancer serve en HTTPS

## Auteur

Christian Ngiamba, étudiant en Mastère Spécialisé Cybersécurité et Cyberdéfense à Télécom Paris.
