# frontend/app.py
import streamlit as st
import random
import string
from _scripts.core.database import DatabaseManager

# 1. Initialize our secure central database driver
@st.cache_resource
def get_db_manager():
    return DatabaseManager()

db_manager = get_db_manager()

# 2. Configure the Web View Title & Navigation Tabs
st.set_page_config(page_title="Genomics Portal", layout="wide")
st.title(" Clinical Genomics Portal & Variant Hub")

tab1, tab2, tab3 = st.tabs(["📋 Register Patient", "Order NGS Test", "🔍 Query Patient Records"])

# --- TAB 1: REGISTER PATIENTS ---
with tab1:
    st.header("Patient Registration Demographics")
    
    with st.form("patient_form", clear_on_submit=True):
        col1, col2 = st.columns(2)
        with col1:
            name = st.text_input("Full Patient Name (e.g., John Doe)")
            mrn = st.text_input("Medical Record Number (MRN)")
        with col2:
            age = st.number_input("Age", min_value=0, max_value=120, value=30, step=1)
            sex = st.selectbox("Biological Sex", ["Male", "Female", "Other"])
            
        submit_patient = st.form_submit_button("Save Patient to Azure")
        
        if submit_patient:
            if not name or not mrn:
                st.error("❌ Both Patient Name and MRN are strictly required fields.")
            else:
                try:
                    conn = db_manager.get_connection()
                    cursor = conn.cursor()
                    
                    # Insert the demographic details into Azure SQL
                    sql = "INSERT INTO patients (mrn, name, age, sex) VALUES (%s, %s, %s, %s);"
                    cursor.execute(sql, (mrn, name, int(age), sex))
                    conn.commit()
                    
                    # Fetch the auto-generated Patient ID to show the user
                    cursor.execute("SELECT patient_id FROM patients WHERE mrn = %s;", (mrn,))
                    generated_id = cursor.fetchone()[0]
                    
                    st.success(f"Patient Registered! Auto-Generated System ID: **{generated_id}**")
                    conn.close()
                except Exception as e:
                    st.error(f"❌ Failed to register patient to Azure: {e}")

# --- TAB 2: ORDER NGS TESTS ---
with tab2:
    st.header("Order Molecular Sequencing Panel")
    
    panel_type = st.selectbox("Select Target Test Panel", [
        "pedonc_v2 (Dx pediatric oncology)", 
        "MRFN (Dx Marfan)", 
        "Epilepsy_com (Dx Comprehensive Epilepsy Panel)",
        "Noonan (Dx Noonan Syndrome Panel)",
        "Epilepsy_Ther (Dx Therapeutic Epilepsy Panel)",
        "PID (Dx Primary Immunodeficiency Panel)",
        "Whole_Exome_Sequencing_v4 (Research Exome Panel)"
    ])
    target_mrn = st.text_input("Enter Patient MRN to verify and link order")
    submit_order = st.button("Generate Electronic Sample ID")
    
    if submit_order:
        if not target_mrn:
            st.error("❌ Please enter a valid MRN.")
        else:
            try:
                conn = db_manager.get_connection()
                cursor = conn.cursor()
                
                # Verify that the patient exists before ordering a test
                cursor.execute("SELECT patient_id, name FROM patients WHERE mrn = %s;", (target_mrn,))
                patient_row = cursor.fetchone()
                
                if patient_row:
                    internal_id, patient_name = patient_row[0], patient_row[1]
                    
                    # Generate a unique clinical sample tracking identifier (e.g., SAM-A892F)
                    random_suffix = ''.join(random.choices(string.ascii_uppercase + string.digits, k=5))
                    generated_sample_id = f"SAM-{random_suffix}"
                    
                    # Save order directly to the samples table
                    sql = "INSERT INTO samples (sample_id, patient_id, test_panel, status) VALUES (%s, %s, %s, 'Pending');"
                    cursor.execute(sql, (generated_sample_id, internal_id, panel_type))
                    conn.commit()
                    
                    st.success(f"📦 Order Placed for **{patient_name}**!")
                    st.info(f"💡 **Assigned Sample ID:** `{generated_sample_id}`\n\nEnsure sequencer raw FastQ files are named `{generated_sample_id}_R1.fastq.gz` so the automation pipeline can process it.")
                else:
                    st.error("❌ Patient MRN not found. Please register the patient in Tab 1 first.")
                conn.close()
            except Exception as e:
                st.error(f"❌ Ordering system error: {e}")

# --- TAB 3: SEARCH RESULTS & VARIANT DATA ---
with tab3:
    st.header("Search Clinical Variant Records")
    search_query = st.text_input("Enter Patient Name to search (e.g., John)")
    
    if search_query:
        try:
            conn = db_manager.get_connection()
            cursor = conn.cursor()
            
            # Complex relational query to fetch patients, linked samples, and identified variants
            sql = """
                SELECT p.patient_id, p.name, p.mrn, s.sample_id, s.test_panel, s.status,
                       v.chrom, v.start_pos, v.ref, v.alt, v.classification
                FROM patients p
                JOIN samples s ON p.patient_id = s.patient_id
                LEFT JOIN variants v ON s.sample_id = v.sample_id
                WHERE p.name LIKE %s;
            """
            cursor.execute(sql, (f"%{search_query}%",))
            rows = cursor.fetchall()
            
            if rows:
                st.write(f"🔍 Found {len(rows)} matching transaction entries:")
                
                # Structure the raw data tuples into an interactive visual spreadsheet
                data_list = []
                for row in rows:
                    data_list.append({
                        "Patient ID": row[0], "Name": row[1], "MRN": row[2],
                        "Sample ID": row[3], "Panel": row[4], "Pipeline Status": row[5],
                        "Chrom": row[6] if row[6] else "N/A",
                        "Position": row[7] if row[7] else "N/A",
                        "Ref": row[8] if row[8] else "N/A",
                        "Alt": row[9] if row[9] else "N/A",
                        "Classification": row[10] if row[10] else "No variants yet"
                    })
                st.dataframe(data_list, use_container_width=True)
            else:
                st.warning("⚠️ No records found matching that name.")
            conn.close()
        except Exception as e:
            st.error(f"❌ Query execution error: {e}")
