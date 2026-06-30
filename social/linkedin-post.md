Après la migration, mes serveurs d'inférence LLM tournaient 35 % moins vite.

Tout accusait le nouveau driver NVIDIA. Le diagnostic disait autre chose.

—

Contexte : migration d'un hyperviseur Proxmox de production qui sert plusieurs agents LLM en local. Du lourd, en une fenêtre :
• Proxmox VE 8.4 → 9.2 (Debian 12 → 13)
• kernel 6.8 → 7.0
• driver NVIDIA 570 → 595 (les anciens ne compilent plus sur le 7.0)
• 4 GPU (2× RTX 4090 + 2× RTX 3090) en passthrough vers des conteneurs LXC
• et la vraie contrainte : AUCUN accès hors-bande. Pas d'IPMI. Un reboot raté = déplacement physique devant la machine.

La migration passe. Puis un serveur tombe de ~37 à 24 tokens/s.

Le réflexe facile : « c'est le nouveau driver / le nouveau kernel ». J'ai refusé d'y croire sans preuve.

Méthode : mesurer, échantillonner les raisons de throttling en temps réel, éliminer une à une (PCIe sous charge ✅ Gen4, thermique ✅ 63°C, persistence ✅, espace utilisateur CUDA ✅).

Coupable : un power cap de 220 W… déjà présent sous l'ancien driver. Pas une régression de la migration.

Preuve par test A/B réversible : 220 W → 24 tok/s, 300 W → 44 tok/s.

Après un balayage perf/watt propre : 3090 calées à 280 W → +58 % de débit. Et surprise, les RTX 4090 n'étaient PAS limitées par la puissance : monter leur cap = 0 gain. On vérifie avant d'agir.

—

Ce que je retiens :

→ Une baisse de perf après migration n'est pas une régression tant qu'on ne l'a pas prouvée. Mesure, n'accuse pas.

→ Sans IPMI, la décision qui change tout : valider que le driver compile pour le nouveau kernel AVANT de rebooter (DKMS, pendant qu'on tourne encore sur l'ancien kernel). On transforme un pari aveugle en opération contrôlée.

→ Sur plusieurs alimentations, le risque se raisonne par rail, jamais sur le total.

→ Avant de relever un power limit, vérifie que le GPU est vraiment limité par la puissance.

—

J'ai écrit le runbook complet : reproductible, commande par commande, avec matrice de décision, rollback par phase et les pièges (nova/nova_core à blacklister, Secure Boot, set complet de device nodes…). Sous licence CC BY-SA.

👉 https://github.com/khemerson/proxmox-pve8to9-gpu-nvidia-runbook

#Proxmox #NVIDIA #LLM #GPU #Infrastructure #DevOps #SelfHosted #Homelab #IAsouveraine #Linux
