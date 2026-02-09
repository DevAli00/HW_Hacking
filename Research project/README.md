# Attaques DoS sur Bus AXI - Projet de Recherche

## Vue d'ensemble

Ce projet de recherche explore les vulnérabilités de sécurité du bus **AXI (Advanced eXtensible Interface)** de Xilinx, en particulier les attaques par **déni de service (DoS)**. L'objectif est de démontrer qu'un IP malveillant connecté à un interconnect AXI peut dégrader, voire bloquer, l'accès au bus pour les autres IPs légitimes.

Tous les testbenches utilisent le **Xilinx AXI VIP (Verification IP)** pour simuler des maîtres AXI (attaquants et victimes) connectés à un design contenant un interconnect AXI et une mémoire BRAM partagée à l'adresse `0x4000_0000`.

---

## Architecture du banc de test

```
                    ┌─────────────────────────────┐
  Victime (VIP 0)  ─┤                             ├─ BRAM
  Attaquant 1 (VIP 1) ─┤   AXI Interconnect        ├─ (0x4000_0000)
  Attaquant 2 (VIP 2) ─┤   (Round-Robin Arbitration)│
  Attaquant 3 (VIP 3) ─┤                             │
                    └─────────────────────────────┘
```

Chaque test suit la même méthodologie :
1. **Mesure de référence (Baseline)** : latence de la victime sans attaque
2. **Lancement de l'attaque** : activation des threads attaquants
3. **Mesure sous attaque** : latence/timeouts de la victime pendant l'attaque
4. **Rapport** : comparaison baseline vs attaque (facteur de ralentissement)

---

## Attaque principale : 09_Outstanding_ReadFlood_1v1.v

**Fichier** : `09_Outstanding_ReadFlood_1v1.v`
**Module** : `tb_attack_read_1vs1`
**Scenario** : 1 Attaquant vs 1 Victime - Outstanding Read Flood

### Principe

Cette attaque est la démonstration la plus représentative d'un scénario réel de DoS matériel. Contrairement aux autres variantes qui utilisent 3 attaquants simultanés, **ce test prouve qu'un seul IP malveillant suffit** pour dégrader significativement les performances d'un IP légitime sur un bus AXI partagé.

L'attaque exploite le mécanisme de **transactions outstanding** du protocole AXI4 complet : au lieu d'attendre la réponse de chaque requête avant d'en émettre une nouvelle (comme en AXI4-Lite), l'attaquant envoie **jusqu'à 16 requêtes de lecture en vol simultanément**, chacune avec un burst maximal de 256 beats. Un seul maître malveillant monopolise ainsi les FIFOs internes de l'interconnect.

### Architecture simplifiée

```
                    ┌─────────────────────────────┐
  Victime (VIP 0)  ─┤                             ├─ BRAM
  Attaquant (VIP 1) ─┤   AXI Interconnect         ├─ (0x4000_0000)
  VIP 2 (IDLE)      ─┤   (Round-Robin Arbitration)│
  VIP 3 (IDLE)      ─┤                             │
                    └─────────────────────────────┘
```

Les VIP 2 et 3 sont instanciés car le block design matériel les requiert, mais ils restent **inactifs pendant toute la simulation**. Cela isole l'impact d'un unique attaquant.

### Configuration de l'attaque

| Paramètre | Valeur | Signification |
|---|---|---|
| `SHARED_ADDR` | `0x4000_0000` | Adresse de base de la BRAM partagée |
| `BURST_LEN` | 255 | Burst maximal AXI4 : 256 beats (1024 octets par transaction) |
| `OUTSTANDING_DEPTH` | 16 | 16 transactions en vol simultanément |
| `INJECTION_DELAY` | 10 ns | 1 nouvelle transaction par cycle d'horloge (100 MHz) |

### Fonctionnement détaillé

#### Phase 1 - Initialisation 

Construction et démarrage des 4 agents VIP. Seul l'attaquant 1 est configuré avec des profondeurs de transaction augmentées (`set_transaction_depth(4096)` et `set_max_item_cnt(10000)`) pour supporter le volume de flooding.

```
victim_agent    = new("Victim",    design_1_i.axi_vip_0.inst.IF);
attacker1_agent = new("Attacker1", design_1_i.axi_vip_1.inst.IF);
attacker2_agent = new("Attacker2", design_1_i.axi_vip_2.inst.IF);  // IDLE
attacker3_agent = new("Attacker3", design_1_i.axi_vip_3.inst.IF);  // IDLE
```

#### Phase 2 - Thread attaquant 

Un unique thread est lancé via `fork/join_none`. La boucle d'attaque fonctionne ainsi :

```
Boucle infinie :
  1. Attendre que attack_enable soit actif
  2. Créer une transaction de lecture AXI4 (burst de 256 beats)
  3. Configurer NO_RETURN (ne pas attendre la réponse)
  4. Envoyer sur le bus via rd_driver.send()
  5. Empiler dans trans_queue
  6. Si trans_queue >= 16 entrées → attendre la plus ancienne
  7. Incrémenter le compteur, attendre 10 ns
  8. Recommencer
```

L'adresse est calculée de manière cyclique : `SHARED_ADDR + ((op_count % 256) * 4)`, ce qui balaie une plage de 1 Ko en continu.

La clé de l'efficacité est la politique `XIL_AXI_NO_RETURN` : l'attaquant n'attend pas la réponse de chaque requête, il les empile. L'interconnect se retrouve avec 16 transactions de lecture en pipeline, chacune nécessitant 256 transferts de données sur le bus.

#### Phase 3 - Mesure baseline 

Avant l'attaque, la victime :
1. Ecrit 256 mots en mémoire (`0xCAFE_0000 | i`)
2. Effectue 10 lectures et mesure la latence moyenne

Cette baseline sert de référence pour quantifier l'impact de l'attaque.

#### Phase 4 - Mesure sous attaque 

Après activation de l'attaque et 20 µs de warmup :
- La victime tente **10 lectures AXI4-Lite**
- Chaque lecture a un **timeout de 200 µs**
- Pour chaque tentative, un `fork/join_any` lance la lecture en parallèle avec un timer

```
fork
  begin  // Tentative de lecture
    victim_agent.AXI4LITE_READ_BURST(...)
    tx_done = 1;
  end
  begin  // Timeout
    #200000ns;
  end
join_any
```

Si la lecture aboutit, sa latence et le facteur de ralentissement (`latency / avg_baseline`) sont affichés. Sinon, un TIMEOUT est rapporté.

#### Phase 5 - Rapport final 

L'attaque est désactivée, et le résultat final est affiché :
```
[RESULT] Final Avg Latency: XXX ns (Y.Yx slowdown)
```


---

## Autres scripts d'attaque

### 05_Outstanding_ReadFlood_3v1.v

**Module** : `tb_attack_read`

Version de l'attaque Outstanding Read avec **3 attaquants** opérant en parallèle via `fork/join_none`. Mêmes paramètres que le 1v1 (`BURST_LEN=255`, `OUTSTANDING_DEPTH=16`, `INJECTION_DELAY=10ns`) mais avec une pression 3x plus importante. Chaque attaquant cible une zone d'adresse décalée (offsets +0, +1024, +2048). Résultat : saturation totale du canal de lecture.

### 06_Outstanding_WriteFlood_3v1.v

**Module** : `tb_outstanding_write_attack`

Variante en écriture. Les 3 attaquants inondent le **canal d'écriture** (AW + W + B) avec des bursts de 256 beats. Chaque beat contient des données malveillantes (`0xA111_xxxx`, `0xA222_xxxx`, `0xA333_xxxx`).

**Différences avec les attaques en lecture :**
- Utilise `wr_driver` au lieu de `rd_driver`
- Nécessite de remplir chaque beat de données (`set_data_beat`)
- Peut provoquer une **corruption des données** de la victime (les écritures malveillantes écrasent la mémoire partagée)
- Vérifie l'intégrité des données lues par la victime après l'attaque

### 07_Outstanding_MixedRW_3v1.v

**Module** : `tb_mixed_outstanding_attack`

Attaque hybride saturant **les deux canaux** (lecture et écriture) simultanément :
- **Attaquant 1** : écritures uniquement (flood du canal W)
- **Attaquant 2** : lectures uniquement (flood du canal R)
- **Attaquant 3** : alternance lecture/écriture ("chaos mode") - ne libère intentionnellement pas les transactions pour maximiser la contention

Bursts réduits à 128 beats pour augmenter la fréquence des arbitrages.

### 08_Outstanding_VariableBurst_3v1.v

**Module** : `tb_variable_burst_attack`

Attaque exploitant les **faiblesses potentielles de l'ordonnanceur** avec des tailles de burst variables et imprévisibles :
- **Attaquant 1** : lectures cycliques (256 / 128 / 64 beats)
- **Attaquant 2** : écritures moyennes (128 beats)
- **Attaquant 3** : écritures courtes (64 beats, tir rapide)

### 01_Prototype_ReadFlood_AXI4Lite.v

**Module** : `tb`

Premier prototype d'attaque DoS par **inondation de lectures AXI4-Lite** bloquantes (une requête, une réponse, puis la suivante). Utilise 2 IPs seulement.

**Limitation** : l'approche AXI4-Lite est peu efficace car l'arbitrage round-robin donne un slot à la victime entre chaque transaction attaquante. C'est cette limitation qui a motivé le passage aux transactions outstanding.

### 02_Prototype_WriteFlood_AXI4Lite.v

**Module** : `tb`

Attaque par **inondation d'écritures bloquantes** AXI4-Lite. L'attaquant envoie des écritures continues avec un délai de 10 ns. La victime tente 10 transactions avec timeout de 50 µs. Moins efficace que les attaques outstanding mais plus simple.

### 03_Advanced_MultiStrategy.v

**Module** : `tb`

Deuxième itération testant **4 stratégies** avec 2 IPs :
1. **SAME_ADDR_READ** : lectures aux mêmes adresses que la victime (contention BRAM)
2. **SAME_ADDR_WRITE** : écritures aux mêmes adresses (corruption + contention)
3. **MIXED_RW** : alternance lecture/écriture
4. **WRITE_FLOOD** : inondation pure en écriture

Inclut un **monitoring des signaux AXI** (ARVALID/ARREADY, AWVALID/AWREADY) pour compter les stalls. Génère un rapport comparatif.

### 04_Consolidated_AllModes.v

**Module** : `tb`

Version consolidée exécutant **5 modes d'attaque** séquentiellement avec 4 IPs (1 victime + 3 attaquants) :
1. Outstanding Reads (agressif, 10 ns)
2. Outstanding Writes (agressif, 10 ns)
3. Outstanding Reads (modéré, 50 ns)
4. Mixed Outstanding R/W
5. Variable Burst Sizes

Génère un **tableau comparatif final** identifiant automatiquement l'attaque la plus efficace.

---

## Evolution 

```
01_Prototype_ReadFlood_AXI4Lite.v    (prototype, 1 attaquant, AXI4-Lite bloquant)
  │
  ├─→ 02_Prototype_WriteFlood_AXI4Lite.v  (flood écritures bloquantes)
  │
  ├─→ 03_Advanced_MultiStrategy.v         (multi-stratégies, monitoring signaux AXI)
  │
  └─→ 04_Consolidated_AllModes.v          (consolidation, 3 attaquants, 5 modes)
        │
        ├─→ 05_Outstanding_ReadFlood_3v1.v     (3 attaquants, read flood)
        ├─→ 06_Outstanding_WriteFlood_3v1.v    (3 attaquants, write flood)
        ├─→ 07_Outstanding_MixedRW_3v1.v       (3 attaquants, mixte)
        ├─→ 08_Outstanding_VariableBurst_3v1.v (3 attaquants, bursts variables)
        └─→ 09_Outstanding_ReadFlood_1v1.v     ★ Attaque principale (1v1, réaliste)
```


