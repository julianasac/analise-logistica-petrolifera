/* ============================================================================
   PROJECTO: Análise de Logística de Distribuição de Combustível
   Base de Dados: LogisticaPetrolifera
   Autora: Juliana Sacramento
   
   DESCRIÇÃO DO PROJECTO
   ----------------------------------------------------------------------------
   Simulação de uma rede de distribuição downstream de combustível em Angola:
   5 terminais de armazenagem abastecem 40 postos de combustível através de
   uma frota de 20 cisternas, ao longo de 24 meses de operação (2024-2025).

   Os dados são fictícios, mas desenhados propositadamente para reproduzir
   3 problemas operacionais reais e recorrentes no sector:
     1. Ruturas de stock nos postos de combustível
     2. Perdas de volume (shrinkage) no transporte terminal → posto
     3. Atrasos de entrega em rotas de longa distância

   Este script está organizado em duas partes:
     PARTE A — Esquema da base de dados (criação das 8 tabelas)
     PARTE B — Queries de análise, organizadas por problema de negócio
   ============================================================================ */


/* ============================================================================
   PARTE A — ESQUEMA DA BASE DE DADOS
   ============================================================================ */

CREATE DATABASE LogisticaPetrolifera;
GO

USE LogisticaPetrolifera;
GO

-- Tabelas de dimensão -------------------------------------------------------

CREATE TABLE Terminais (
    Terminal_id VARCHAR(5) PRIMARY KEY,
    Nome_Terminal VARCHAR(100),
    Provincia VARCHAR(50),
    Capacidade_litros BIGINT
);

CREATE TABLE Produtos (
    Produto_id VARCHAR(5) PRIMARY KEY,
    Nome_Produto VARCHAR(50),
    Preco_referencia_kz DECIMAL(10,2)
);

CREATE TABLE Postos (
    Posto_id VARCHAR(5) PRIMARY KEY,
    Nome_Posto VARCHAR(100),
    Provincia VARCHAR(50),
    Terminal_id VARCHAR(5) FOREIGN KEY REFERENCES Terminais(Terminal_id),
    Tipo VARCHAR(20),          -- 'Urbano' ou 'Estrada'
    Capacidade_litros INT
);

CREATE TABLE Cisternas (
    Cisterna_id VARCHAR(5) PRIMARY KEY,
    Matricula VARCHAR(20),
    Capacidade_litros INT,
    Terminal_base_id VARCHAR(5) FOREIGN KEY REFERENCES Terminais(Terminal_id)
);

CREATE TABLE Rotas (
    Rota_id VARCHAR(5) PRIMARY KEY,
    Terminal_id VARCHAR(5) FOREIGN KEY REFERENCES Terminais(Terminal_id),
    Posto_id VARCHAR(5) FOREIGN KEY REFERENCES Postos(Posto_id),
    Distancia_km INT,
    Velocidade_media_kmh INT
);

-- Tabelas de factos -----------------------------------------------------------

CREATE TABLE Entregas (
    Entrega_id VARCHAR(10) PRIMARY KEY,
    Data DATE,
    Terminal_id VARCHAR(5) FOREIGN KEY REFERENCES Terminais(Terminal_id),
    Posto_id VARCHAR(5) FOREIGN KEY REFERENCES Postos(Posto_id),
    Cisterna_id VARCHAR(5) FOREIGN KEY REFERENCES Cisternas(Cisterna_id),
    Produto_id VARCHAR(5) FOREIGN KEY REFERENCES Produtos(Produto_id),
    Volume_planeado_litros DECIMAL(10,2),
    Volume_entregue_litros DECIMAL(10,2),   -- < planeado devido a shrinkage
    Hora_saida_planeada TIME,
    Hora_chegada_planeada TIME,
    Hora_chegada_real TIME,                 -- > planeada em rotas longas
    Distancia_km INT
);

CREATE TABLE NiveisStock_Posto (
    Posto_id VARCHAR(5) FOREIGN KEY REFERENCES Postos(Posto_id),
    Data DATE,
    Produto_id VARCHAR(5) FOREIGN KEY REFERENCES Produtos(Produto_id),
    Stock_inicial_litros DECIMAL(10,2),
    Consumo_base_litros DECIMAL(10,2),
    Fator_variacao DECIMAL(6,4),
    Vendas_potenciais_litros DECIMAL(10,2),
    Entrega_recebida_litros DECIMAL(10,2),
    Vendas_litros DECIMAL(10,2),
    Ruptura BIT,                            -- 1 = procura excedeu stock disponível
    Litros_nao_vendidos DECIMAL(10,2),      -- procura perdida por falta de stock
    Stock_final_litros DECIMAL(10,2),
    PRIMARY KEY (Posto_id, Data, Produto_id)
);

CREATE TABLE NiveisStock_Terminal (
    Terminal_id VARCHAR(5) FOREIGN KEY REFERENCES Terminais(Terminal_id),
    Data DATE,
    Produto_id VARCHAR(5) FOREIGN KEY REFERENCES Produtos(Produto_id),
    Stock_inicial_litros DECIMAL(12,2),
    Saidas_litros DECIMAL(12,2),
    Entrada_reabastecimento_litros DECIMAL(12,2),  -- reabastecimento automático (gatilho 20%, repõe a 90%)
    Stock_final_litros DECIMAL(12,2),
    Taxa_utilizacao DECIMAL(6,4),
    PRIMARY KEY (Terminal_id, Data, Produto_id)
);
GO


/* ============================================================================
   PARTE B — ANÁLISE DE DADOS
   ============================================================================ */

/* ----------------------------------------------------------------------------
   PROBLEMA 1: RUTURAS DE STOCK NOS POSTOS
   
   Resultado: 13,16% dos dias com ruptura | ~9,8M litros perdidos
              ~3,44 mil milhões Kz de receita potencialmente perdida (24 meses)
   
   Conclusão: a ruptura não é uniforme na rede — concentra-se em postos
   servidos por rotas longas (>80km) E terminais de menor capacidade.
   O Terminal da Huíla (T03) é o pior caso: 32,6% de ruptura, o pior
   resultado combinado de distância + capacidade reduzida.
   ---------------------------------------------------------------------------- */

-- 1.1 — Visão geral: dimensão do problema
SELECT 
    COUNT(*) AS total_dias_analisados,
    SUM(CASE WHEN Ruptura = 1 THEN 1 ELSE 0 END) AS dias_com_ruptura,
    CAST(SUM(CASE WHEN Ruptura = 1 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) * 100 AS percentagem_ruptura,
    SUM(Litros_nao_vendidos) AS total_litros_perdidos,
    SUM(Litros_nao_vendidos * 350) AS receita_perdida_estimada_kz  -- 350 Kz = preço médio aproximado
FROM dbo.NiveisStock_Posto;

-- 1.2 — Concentração do problema por posto
SELECT 
    n.Posto_id,
    p.Nome_Posto,
    p.Provincia,
    p.Tipo,
    COUNT(*) AS total_dias,
    SUM(CASE WHEN n.Ruptura = 1 THEN 1 ELSE 0 END) AS dias_com_ruptura,
    CAST(SUM(CASE WHEN n.Ruptura = 1 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) * 100 AS percentagem_ruptura,
    SUM(n.Litros_nao_vendidos) AS litros_perdidos
FROM dbo.NiveisStock_Posto n
JOIN dbo.Postos p ON n.Posto_id = p.Posto_id
GROUP BY n.Posto_id, p.Nome_Posto, p.Provincia, p.Tipo
ORDER BY percentagem_ruptura DESC;

-- 1.3 — Causa-raiz: correlação entre distância da rota e taxa de ruptura
SELECT 
    CASE 
        WHEN r.Distancia_km <= 20 THEN '1. Até 20km'
        WHEN r.Distancia_km <= 50 THEN '2. 21-50km'
        WHEN r.Distancia_km <= 80 THEN '3. 51-80km'
        ELSE '4. Acima de 80km'
    END AS faixa_distancia,
    COUNT(DISTINCT n.Posto_id) AS num_postos,
    CAST(SUM(CASE WHEN n.Ruptura = 1 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) * 100 AS percentagem_ruptura_media
FROM dbo.NiveisStock_Posto n
JOIN dbo.Rotas r ON n.Posto_id = r.Posto_id
GROUP BY CASE 
        WHEN r.Distancia_km <= 20 THEN '1. Até 20km'
        WHEN r.Distancia_km <= 50 THEN '2. 21-50km'
        WHEN r.Distancia_km <= 80 THEN '3. 51-80km'
        ELSE '4. Acima de 80km'
    END
ORDER BY faixa_distancia;

-- 1.4 — Causa-raiz: taxa de ruptura por terminal de origem
SELECT 
    t.Terminal_id,
    t.Nome_Terminal,
    t.Capacidade_litros,
    COUNT(DISTINCT n.Posto_id) AS num_postos,
    CAST(SUM(CASE WHEN n.Ruptura = 1 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) * 100 AS percentagem_ruptura_media
FROM dbo.NiveisStock_Posto n
JOIN dbo.Postos p ON n.Posto_id = p.Posto_id
JOIN dbo.Terminais t ON p.Terminal_id = t.Terminal_id
GROUP BY t.Terminal_id, t.Nome_Terminal, t.Capacidade_litros
ORDER BY percentagem_ruptura_media DESC;


/* ----------------------------------------------------------------------------
   PROBLEMA 2: SHRINKAGE / PERDAS DE VOLUME NAS ENTREGAS
   
   Resultado: 1,98% de shrinkage médio | ~4,95M litros perdidos
              ~1,73 mil milhões Kz de custo estimado (24 meses)
   
   Conclusão: ao contrário da ruptura de stock, o shrinkage é SISTÉMICO —
   distribuído de forma consistente por toda a frota de cisternas (1,77%-
   2,13%) e sem correlação com a distância da rota. Não há uma causa
   localizável; a recomendação é uma auditoria de calibração aplicada a
   toda a operação, não uma intervenção pontual.
   ---------------------------------------------------------------------------- */

-- 2.1 — Visão geral: dimensão do problema
SELECT 
    COUNT(*) AS total_entregas,
    SUM(Volume_planeado_litros) AS total_planeado_litros,
    SUM(Volume_entregue_litros) AS total_entregue_litros,
    SUM(Volume_planeado_litros - Volume_entregue_litros) AS total_perdido_litros,
    CAST(SUM(Volume_planeado_litros - Volume_entregue_litros) AS FLOAT) 
        / SUM(Volume_planeado_litros) * 100 AS percentagem_shrinkage_media,
    SUM((Volume_planeado_litros - Volume_entregue_litros) * 350) AS custo_estimado_kz
FROM dbo.Entregas;

-- 2.2 — Hipótese testada (e descartada): concentração numa cisterna específica
--       Nota metodológica: shrinkage_medio_pct usa SOMA(perdido)/SOMA(planeado) —
--       uma média ponderada pelo volume, não a média simples das percentagens de
--       cada entrega. Esta é a mesma lógica aplicada nas medidas DAX do Power BI,
--       garantindo que os dois números coincidem exactamente.
SELECT 
    Cisterna_id,
    COUNT(*) AS total_entregas,
    CAST(SUM(Volume_planeado_litros - Volume_entregue_litros) AS FLOAT) 
        / SUM(Volume_planeado_litros) * 100 AS shrinkage_medio_pct,
    SUM(Volume_planeado_litros - Volume_entregue_litros) AS total_litros_perdidos
FROM dbo.Entregas
GROUP BY Cisterna_id
ORDER BY shrinkage_medio_pct DESC;
-- Resultado: variação de apenas 0,36 p.p. entre a melhor e a pior cisterna — sem padrão relevante

-- 2.3 — Hipótese testada (e descartada): correlação com a distância da rota
--       (mesma nota metodológica da query 2.2 — média ponderada por volume)
SELECT 
    CASE 
        WHEN Distancia_km <= 20 THEN '1. Até 20km'
        WHEN Distancia_km <= 50 THEN '2. 21-50km'
        WHEN Distancia_km <= 80 THEN '3. 51-80km'
        ELSE '4. Acima de 80km'
    END AS faixa_distancia,
    COUNT(*) AS num_entregas,
    CAST(SUM(Volume_planeado_litros - Volume_entregue_litros) AS FLOAT) 
        / SUM(Volume_planeado_litros) * 100 AS shrinkage_medio_pct
FROM dbo.Entregas
GROUP BY CASE 
        WHEN Distancia_km <= 20 THEN '1. Até 20km'
        WHEN Distancia_km <= 50 THEN '2. 21-50km'
        WHEN Distancia_km <= 80 THEN '3. 51-80km'
        ELSE '4. Acima de 80km'
    END
ORDER BY faixa_distancia;
-- Resultado: praticamente idêntico entre faixas (1,94%-2,01%) — sem tendência


/* ----------------------------------------------------------------------------
   PROBLEMA 3: ATRASOS DE ENTREGA
   
   Resultado: atraso médio de 7 min em rotas ≤80km, subindo para 37 min
              em rotas >80km (mais de 5x superior)
   
   Nota técnica: o cálculo de diferença de horas (tipo TIME) exige
   tratamento da "volta ao relógio" quando a chegada acontece perto da
   meia-noite — ver a expressão CASE abaixo.
   
   Conclusão: confirma e reforça a causa-raiz do Problema 1 — rotas
   longas comprometem a fiabilidade do reabastecimento em toda a cadeia.
   ---------------------------------------------------------------------------- */

-- 3.1 — Visão geral: dimensão do problema
SELECT 
    COUNT(*) AS total_entregas,
    AVG(DATEDIFF(MINUTE, Hora_chegada_planeada, Hora_chegada_real)) AS atraso_medio_minutos_bruto,
    SUM(CASE WHEN Hora_chegada_real > Hora_chegada_planeada THEN 1 ELSE 0 END) AS entregas_atrasadas,
    CAST(SUM(CASE WHEN Hora_chegada_real > Hora_chegada_planeada THEN 1 ELSE 0 END) AS FLOAT) 
        / COUNT(*) * 100 AS percentagem_atrasadas
FROM dbo.Entregas;

-- 3.2 — Causa-raiz: atraso médio corrigido, por faixa de distância
--       (correcção necessária: TIME não tem noção de "dia", pelo que uma
--        chegada pouco depois da meia-noite face a uma chegada planeada
--        antes da meia-noite gera uma diferença negativa artificial)
SELECT 
    CASE 
        WHEN Distancia_km <= 20 THEN '1. Até 20km'
        WHEN Distancia_km <= 50 THEN '2. 21-50km'
        WHEN Distancia_km <= 80 THEN '3. 51-80km'
        ELSE '4. Acima de 80km'
    END AS faixa_distancia,
    COUNT(*) AS num_entregas,
    AVG(
        CASE 
            WHEN DATEDIFF(MINUTE, Hora_chegada_planeada, Hora_chegada_real) < -720 
                THEN DATEDIFF(MINUTE, Hora_chegada_planeada, Hora_chegada_real) + 1440
            WHEN DATEDIFF(MINUTE, Hora_chegada_planeada, Hora_chegada_real) > 720 
                THEN DATEDIFF(MINUTE, Hora_chegada_planeada, Hora_chegada_real) - 1440
            ELSE DATEDIFF(MINUTE, Hora_chegada_planeada, Hora_chegada_real)
        END
    ) AS atraso_medio_minutos_corrigido
FROM dbo.Entregas
GROUP BY CASE 
        WHEN Distancia_km <= 20 THEN '1. Até 20km'
        WHEN Distancia_km <= 50 THEN '2. 21-50km'
        WHEN Distancia_km <= 80 THEN '3. 51-80km'
        ELSE '4. Acima de 80km'
    END
ORDER BY faixa_distancia;


/* ----------------------------------------------------------------------------
   SÍNTESE FINAL — A NARRATIVA INTEGRADA

   Os três problemas partilham uma causa-raiz comum: a distância das rotas
   de distribuição. Esta query final junta atraso médio e taxa de ruptura
   lado a lado, por categoria de rota, demonstrando a cadeia causal:

        Rota longa → maior variabilidade no tempo de entrega →
        reabastecimento menos fiável → ruptura de stock mais frequente

   Resultado:
     Rotas Normais (≤80km): 7 min de atraso médio  |  9,5% de ruptura
     Rotas Longas  (>80km): 37 min de atraso médio  |  27,9% de ruptura

   Recomendação de negócio: o investimento prioritário não deve ser
   uniforme na rede — deve ser dirigido especificamente às rotas e
   terminais de maior distância (particularmente Huíla e Cabinda), seja
   por aumento de capacidade de armazenagem local, seja por maior
   frequência de reabastecimento nessas rotas específicas. O shrinkage,
   por ser sistémico, justifica uma intervenção diferente: auditoria de
   calibração aplicada à frota inteira, não localizada.
   ---------------------------------------------------------------------------- */

WITH CategoriaRota AS (
    SELECT Posto_id, 
           CASE WHEN Distancia_km > 80 THEN 'Rotas Longas (>80km)' ELSE 'Rotas Normais (<=80km)' END AS categoria
    FROM dbo.Rotas
),
AtrasosPorCategoria AS (
    SELECT c.categoria,
           AVG(CASE 
                   WHEN DATEDIFF(MINUTE, e.Hora_chegada_planeada, e.Hora_chegada_real) < -720 
                       THEN DATEDIFF(MINUTE, e.Hora_chegada_planeada, e.Hora_chegada_real) + 1440
                   WHEN DATEDIFF(MINUTE, e.Hora_chegada_planeada, e.Hora_chegada_real) > 720 
                       THEN DATEDIFF(MINUTE, e.Hora_chegada_planeada, e.Hora_chegada_real) - 1440
                   ELSE DATEDIFF(MINUTE, e.Hora_chegada_planeada, e.Hora_chegada_real)
               END) AS atraso_medio_min
    FROM dbo.Entregas e
    JOIN CategoriaRota c ON e.Posto_id = c.Posto_id
    GROUP BY c.categoria
),
RupturaPorCategoria AS (
    SELECT c.categoria,
           CAST(SUM(CASE WHEN n.Ruptura = 1 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) * 100 AS percentagem_ruptura
    FROM dbo.NiveisStock_Posto n
    JOIN CategoriaRota c ON n.Posto_id = c.Posto_id
    GROUP BY c.categoria
)
SELECT a.categoria, a.atraso_medio_min, r.percentagem_ruptura
FROM AtrasosPorCategoria a
JOIN RupturaPorCategoria r ON a.categoria = r.categoria;
