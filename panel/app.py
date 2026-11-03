"""
Aurora Market · Panel de seguimiento comercial.

Lee exclusivamente de la capa de consumo (esquema consume), nunca de los CSV ni de core.
Arranca con:  docker compose up -d   ->   http://localhost:8501
"""

import os

import altair as alt
import pandas as pd
import psycopg
import streamlit as st

ESQUEMA = os.environ.get("ESQUEMA_CONSUMO", "consume")

st.set_page_config(page_title="Aurora Market · Panel comercial", layout="wide")


# Datos

@st.cache_data(ttl=300)
def consulta(sql: str, params: tuple = ()) -> pd.DataFrame:
    with psycopg.connect() as conn, conn.cursor() as cur:
        cur.execute(sql.replace("{e}", ESQUEMA), params)
        columnas = [d.name for d in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=columnas)


def euros(valor: float) -> str:
    return f"{valor:,.0f} €".replace(",", ".")


def numero(valor: float) -> str:
    return f"{valor:,.0f}".replace(",", ".")


segmentos = consulta("SELECT nombre, prioridad, accion_recomendada FROM {e}.segmento ORDER BY prioridad")
orden_segmentos = segmentos["nombre"].tolist()
paises_disponibles = consulta(
    "SELECT DISTINCT pais FROM {e}.dim_cliente WHERE pais IS NOT NULL ORDER BY 1")["pais"].tolist()
fecha_ref = consulta("SELECT max(fecha_calculo) AS f FROM {e}.cliente_360")["f"].iloc[0]
if fecha_ref is None or pd.isna(fecha_ref):
    st.title("Aurora Market · Panel comercial")
    st.info("Todavía no hay datos procesados. Ejecuta la carga y el procesamiento:\n\n"
            "`docker compose run --rm ingesta inicial` · `delta` · `procesar`\n\n"
            "y recarga esta página.")
    st.cache_data.clear()
    st.stop()

# Cabecera y filtro

st.title("Aurora Market · Panel comercial")
st.caption(f"Datos hasta el {fecha_ref:%d/%m/%Y} · Ventas = pedidos entregados · Fuente: capa de consumo")

paises = st.sidebar.multiselect("País", paises_disponibles, default=[],
                                placeholder="Todos los países")
todos = len(paises) == 0
# Filtro común: sin selección se incluyen también las ventas sin cliente identificado
filtro_cliente = "(%s OR c.pais = ANY(%s))"
params_pais = (todos, paises)

st.sidebar.markdown("**Segmentos**")
for _, s in segmentos.iterrows():
    st.sidebar.caption(f"**{s['nombre']}** · {s['accion_recomendada']}")

# Key Perfomance Indicator (KPI)

kpi_ventas = consulta(f"""
    SELECT count(DISTINCT f.pedido_id) AS pedidos, coalesce(sum(f.importe_neto), 0) AS ingresos
    FROM {{e}}.fact_ventas f JOIN {{e}}.dim_cliente c USING (cliente_id)
    WHERE f.es_venta_valida AND {filtro_cliente}""", params_pais).iloc[0]
kpi_clientes = consulta(f"""
    SELECT count(*) AS clientes, count(*) FILTER (WHERE x.num_pedidos > 0) AS con_compras
    FROM {{e}}.cliente_360 x JOIN {{e}}.dim_cliente c USING (cliente_id)
    WHERE {filtro_cliente}""", params_pais).iloc[0]
kpi_audiencia = consulta(f"""
    SELECT count(*) AS contactables FROM {{e}}.audiencia_campana a JOIN {{e}}.dim_cliente c USING (cliente_id)
    WHERE a.campana_id = (SELECT max(campana_id) FROM {{e}}.audiencia_campana) AND {filtro_cliente}""",
    params_pais).iloc[0]

k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Clientes", numero(kpi_clientes["clientes"]),
          help="Clientes únicos tras deduplicar")
k2.metric("Con compras", numero(kpi_clientes["con_compras"]),
          help="Clientes con al menos un pedido entregado")
k3.metric("Pedidos entregados", numero(kpi_ventas["pedidos"]))
k4.metric("Ingresos", euros(float(kpi_ventas["ingresos"])),
          help="Importe neto (con descuentos, sin impuestos) de pedidos entregados")
k5.metric("Contactables", numero(kpi_audiencia["contactables"]),
          help="Clientes en la audiencia: consentimiento explícito y email válido")

st.divider()

# Segmentos y evolución

col_izq, col_der = st.columns(2)

with col_izq:
    st.subheader("Clientes por segmento")
    por_segmento = consulta(f"""
        SELECT x.segmento, count(*) AS clientes, coalesce(sum(x.importe_total), 0) AS importe
        FROM {{e}}.cliente_360 x JOIN {{e}}.dim_cliente c USING (cliente_id)
        WHERE {filtro_cliente}
        GROUP BY 1""", params_pais)
    por_segmento["importe"] = por_segmento["importe"].astype(float)
    por_segmento["pct_clientes"] = por_segmento["clientes"] / por_segmento["clientes"].sum()
    por_segmento["pct_importe"] = por_segmento["importe"] / max(por_segmento["importe"].sum(), 1)
    grafico = alt.Chart(por_segmento).mark_bar().encode(
        x=alt.X("clientes:Q", title="Clientes", axis=alt.Axis(format="d")),
        y=alt.Y("segmento:N", sort=orden_segmentos, title=None),
        color=alt.value("#2563a8"),
        tooltip=[alt.Tooltip("segmento:N", title="Segmento"),
                 alt.Tooltip("clientes:Q", title="Clientes", format=",.0f"),
                 alt.Tooltip("pct_clientes:Q", title="% de clientes", format=".1%"),
                 alt.Tooltip("importe:Q", title="Importe (€)", format=",.0f"),
                 alt.Tooltip("pct_importe:Q", title="% del importe", format=".1%")],
    ).properties(height=320)
    st.altair_chart(grafico, use_container_width=True)
    campeones = por_segmento[por_segmento["segmento"] == "Campeones"]
    if not campeones.empty:
        st.caption(f"Los Campeones son el {campeones['pct_clientes'].iloc[0]:.0%} de los clientes "
                   f"y generan el {campeones['pct_importe'].iloc[0]:.0%} del importe.")

with col_der:
    st.subheader("Evolución mensual de las ventas")
    mensual = consulta(f"""
        SELECT make_date(d.anio, d.mes, 1) AS mes, ca.nombre AS canal, sum(f.importe_neto) AS importe
        FROM {{e}}.fact_ventas f
        JOIN {{e}}.dim_fecha d    USING (fecha_id)
        JOIN {{e}}.dim_canal ca   USING (canal_id)
        JOIN {{e}}.dim_cliente c  USING (cliente_id)
        WHERE f.es_venta_valida AND {filtro_cliente}
        GROUP BY 1, 2 ORDER BY 1""", params_pais)
    mensual["importe"] = mensual["importe"].astype(float)
    meses_es = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
    mensual["etiqueta"] = mensual["mes"].map(lambda m: f"{meses_es[m.month - 1]} {m:%y}")
    orden_meses = mensual.sort_values("mes")["etiqueta"].unique().tolist()
    grafico = alt.Chart(mensual).mark_bar().encode(
        x=alt.X("etiqueta:O", sort=orden_meses, title=None, axis=alt.Axis(labelAngle=-45)),
        y=alt.Y("sum(importe):Q", title="Importe (€)", axis=alt.Axis(format="~s")),
        color=alt.Color("canal:N", title="Canal", scale=alt.Scale(range=["#2563a8", "#7fb3e0", "#f28e2b"])),
        tooltip=[alt.Tooltip("etiqueta:O", title="Mes"), alt.Tooltip("canal:N", title="Canal"),
                 alt.Tooltip("importe:Q", title="Importe (€)", format=",.0f")],
    ).properties(height=320)
    st.altair_chart(grafico, use_container_width=True)
    st.caption("El último mes está incompleto: los datos llegan hasta la fecha de referencia.")

st.divider()

# Categorías y productos por segmento

st.subheader("Categorías y productos más relevantes por segmento")
col_izq, col_der = st.columns([3, 2])

with col_izq:
    cat_segmento = consulta(f"""
        SELECT x.segmento, p.categoria, sum(f.importe_neto) AS importe
        FROM {{e}}.fact_ventas f
        JOIN {{e}}.dim_producto p  USING (producto_id)
        JOIN {{e}}.cliente_360 x   USING (cliente_id)
        JOIN {{e}}.dim_cliente c   USING (cliente_id)
        WHERE f.es_venta_valida AND p.producto_id > 0 AND {filtro_cliente}
        GROUP BY 1, 2""", params_pais)
    cat_segmento["importe"] = cat_segmento["importe"].astype(float)
    cat_segmento["peso"] = cat_segmento["importe"] / cat_segmento.groupby("segmento")["importe"].transform("sum")
    base = alt.Chart(cat_segmento).encode(
        x=alt.X("categoria:N", title=None, axis=alt.Axis(labelAngle=0, labelOverlap=False, orient="top")),
        y=alt.Y("segmento:N", sort=orden_segmentos, title=None),
    )
    mapa = base.mark_rect().encode(
        color=alt.Color("peso:Q", scale=alt.Scale(scheme="blues"), legend=None),
        tooltip=[alt.Tooltip("segmento:N", title="Segmento"), alt.Tooltip("categoria:N", title="Categoría"),
                 alt.Tooltip("importe:Q", title="Importe (€)", format=",.0f"),
                 alt.Tooltip("peso:Q", title="Peso en el segmento", format=".1%")],
    )
    texto = base.mark_text(fontSize=11).encode(
        text=alt.Text("peso:Q", format=".0%"),
        color=alt.condition("datum.peso > 0.22", alt.value("white"), alt.value("black")),
    )
    st.altair_chart((mapa + texto).properties(height=300), use_container_width=True)
    st.caption("Cada fila suma 100 %: qué parte del gasto de cada segmento va a cada categoría.")

with col_der:
    segmentos_con_compras = [s for s in orden_segmentos if s != "Sin compras"]
    elegido = st.selectbox("Productos más vendidos del segmento", segmentos_con_compras)
    top = consulta(f"""
        SELECT p.nombre AS producto, p.categoria, sum(f.cantidad) AS unidades, sum(f.importe_neto) AS importe
        FROM {{e}}.fact_ventas f
        JOIN {{e}}.dim_producto p USING (producto_id)
        JOIN {{e}}.cliente_360 x  USING (cliente_id)
        JOIN {{e}}.dim_cliente c  USING (cliente_id)
        WHERE f.es_venta_valida AND p.producto_id > 0 AND x.segmento = %s AND {filtro_cliente}
        GROUP BY 1, 2 ORDER BY importe DESC LIMIT 8""", (elegido, *params_pais))
    top["importe"] = top["importe"].astype(float).map(euros)
    top["unidades"] = top["unidades"].astype(int)
    st.dataframe(top, hide_index=True, use_container_width=True)
