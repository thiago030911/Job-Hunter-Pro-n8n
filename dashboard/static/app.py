import streamlit as st
import pandas as pd
import plotly.express as px

st.set_page_config(page_title="Job Hunter Dashboard", layout="wide")

st.title("🎯 Job Hunter Pro Dashboard")
st.markdown("Sistema de búsqueda automatizada de empleos")

col1, col2, col3 = st.columns(3)
with col1:
    st.metric("Empleos Totales", "0")
with col2:
    st.metric("Puntaje Promedio", "0.0")
with col3:
    st.metric("Mejores Ofertas", "0")

st.info("🔧 El sistema está iniciando. Los datos aparecerán después de la primera búsqueda.")